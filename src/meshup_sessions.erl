%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Session guarantees.
%%% Sessions provide the AD of ACID. Write-sets are written to durable storage
%%% either in their entirety or not at all. No attempt is made to isolate
%%% concurrent sessions from one another. We assume that the underlying storage
%%% substrate doesn't support atomic operations on more than a single key (and
%%% even if it did, since write-sets may contain data for different DBs,
%%% atomicity would require some additional thought).
%%% @copyright 2011 Klarna AB
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%
%%%   Copyright 2011-2013 Klarna AB
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

%%%_* Module declaration ===============================================
-module(meshup_sessions).
-compile({no_auto_import,[get/1, put/2]}).

%%%_* Exports ==========================================================
%% Continuations
-export([ collect/0
        , inspect/1
        , load/1
        , save/1
        ]).

%% Commit
-export([ cancel/1
        , persist/1
        ]).

%% Recovery
-export([ initial_state/0
        , is_halting_state/1
        , redo/2
        , salvage/1
        , state/2
        ]).

%% Session ADT
-export([ computation/1
        , fresh_id/0
        , id/1
        , is_mode/1
        , is_session/1
        , merge/2
        , mode/1
        , new_session/3
        , new/4
        , older_than/3
        , originated_on/2
        ]).

-export_type([ id/0
             , mode/0
             , session/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/logging.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

-include("shared.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-record(session,
        { id=throw('#session.id')                   :: id()
        , computation=throw('#session.computation') :: computation()
        , mode=async                                :: mode()
        , compress=false                            :: boolean()
        , node=node()                               :: node()
        , timestamp=tulib_util:timestamp()          :: non_neg_integer()
        }).

-type computation() :: meshup_endpoint:computation().
-opaque session()   :: #session{}.
-type id()          :: _.
-type mode()        :: async | in_process | write_set.

%%%_ * ADT -------------------------------------------------------------
fresh_id() ->
  case application:get_env(meshup, id_generator) of
    {ok, {M,F,A}} -> {ok, ID} = apply(M, F, A), ID;
    undefined     -> tulib_util:timestamp()
  end.

is_mode(X) -> X =:= async orelse X =:= in_process orelse X =:= write_set.

-spec new(id(), computation(), mode(), boolean()) -> session().
new(ID, C, M, Z) -> #session{id=ID, computation=C, mode=M, compress=Z}.

%% Internal use only!
new_session(ID, C, TS) -> #session{id=ID, computation=C, timestamp=TS}.

is_session(#session{}) -> true;
is_session(_)          -> false.

id(#session{id=ID})                  -> ID.
computation(#session{computation=C}) -> C.
mode(#session{mode=M})               -> M.

older_than(#session{timestamp=TS}, Now, Time) -> TS < Now - Time.

originated_on(#session{node=Node}, Node) -> true;
originated_on(#session{},          _)    -> false.

%% Sessions are started on one node but may be resumed on different nodes.
merge(#session{id=ID, computation=C1, mode=M, compress=C, node=N, timestamp=TS},
      #session{id=ID, computation=C2, mode=M, compress=C, node=N, timestamp=TS}) ->
  #session{ id          = ID
          , computation = meshup_endpoint:merge(C1, C2)
          , mode        = M
          , compress    = C
          , node        = N
          , timestamp   = TS
          }.

%%%_ * Continuations ---------------------------------------------------
-spec save(session())           -> maybe(_, _).
save(#session{id=ID} = Session) -> put([saved, ID], compress(Session)).

-spec load(id()) -> maybe(session(), _).
load(ID) ->
  case get([saved, ID]) of
    {ok, Session}    -> del([saved, ID]), {ok, uncompress(Session)};
    {error, _} = Err -> Err
  end.

inspect(ID) ->
  case get([saved, ID]) of
    {ok, Session}    -> {ok, uncompress(Session)};
    {error, _} = Err -> Err
  end.


compress(#session{compress=false} = S) -> S;
compress(#session{id=_ID, computation=C, compress=true} = S0) ->
  S = S0#session{computation=meshup_endpoint:compress(C)},
  ?debug("~p: before: ~p: after: ~p",
         [_ID, tulib_util:size(S0), tulib_util:size(S)]),
  S.

uncompress(#session{compress=false} = S) -> S;
uncompress(#session{computation=C, compress=true} = S) ->
  S#session{computation=meshup_endpoint:uncompress(C)}.


-spec collect() -> ok.
%% @doc Garbage collect stale sessions.
collect() ->
  collect(1000 * 1000 * 60 * 60). %60 minutes
collect(MaxAge) ->
  Now            = tulib_util:timestamp(),
  {ok, Sessions} = get(saved),
  lists:foreach(
    fun(#session{id=ID} = Session) ->
      [begin
         put([stale, ID], Session),
         del([saved, ID])
       end || older_than(Session, Now, MaxAge)]
    end, Sessions).

%%%_ * persist/2 -------------------------------------------------------
%% Commit Protocol
%% ===============
%% We want to guarantee that the database converges - as quickly as
%% possible - to a state where either all or none of the information
%% accumulated during a workflow has been written.
%%
%% The message flow is as follows.
%% For the `async' case:
%%
%% client         0------------------------------------
%%                 \                     /
%% server         --1-------------------7--------------
%%                   \                 /
%% worker         ----2-------4-------6----------------
%%                     \     / \     / \
%% committer      ------\---/---\---/---8---10---------
%%                       \ /     \ /     \ /  \
%% session logger --------3-------5-------9----11------
%%
%% 0) Client makes request
%% 1) Server spawns worker to handle request
%% 2) Worker services request; initiates commit protocol
%% 3) Logger records PREPARE
%% 4) Worker writes session to session store
%% 5) Logger records LOG
%% 6) Worker spawns committer; returns to server
%% 7) Server returns to client
%% 8) Committer writes session state to app stores
%% 9) Logger records COMMIT
%% 10) Committer deletes session from session store
%% 11) Logger records CLEANUP
%%
%% Note that we return to the client once the result of a workflow has
%% been _logged_. The real commit happens asynchronously in the
%% background.
%%
%% Failure Modes
%% =============
%% A) Crash before 3.
%%    No persistent state touched, all transient state lost.
%%    Request fails.
%%
%% B) Crash before 5.
%%    State may or may not have been written to session store.
%%    Recovery will clean up. Request fails.
%%
%% C) Crash between 5 and 7.
%%    State will be persisted but request fails.
%%    Inconsistent database.
%%
%% D) Crash after 7.
%%    Request succeeds. State will show up in database eventually.
%%
%% For the `in_process' case:
%% WRITEME
%%
%% Implementation
%% ==============
%% The process outlined above yields a commit protocol with four
%% steps:
%%   1) Phase 1
%%   1.1) PREPARE
%%   1.2) LOG
%%   2) Phase2
%%   2.1) COMMIT
%%   2.2) CLEANUP
%% REDO-logging (Phase1) must be done synchronously.
%% The remainder of the protocol (Phase 2) may be done in the
%% background.
persist(#session{mode=Mode} = Session) ->
  Phase1 = ?thunk(eval([prepare, log], Session)),
  Phase2 = ?thunk(eval([commit, cleanup], Session)),
  tulib_maybe:lift(?thunk(
    Phase1(),
    if Mode =:= async      -> proc_lib:spawn(Phase2);
       Mode =:= in_process -> Phase2();
       Mode =:= write_set  -> Phase2()
    end)).

%% Each step in the commit protocol has a corresponding operator.
%% Each operator indicates failure by crashing and notifies the
%% session logger upon success.
eval(Ops, Session) when is_list(Ops) ->
  [eval(Op, Session) || Op <- Ops],
  ok;
eval(prepare, #session{id=ID}) ->
  notify(ID, prepare),
  ?debug("~p: prepare", [ID]),
  ?increment([sessions, prepare]);
eval(log, #session{id=ID} = Session) ->
  ok = put([wal, ID], Session), %replicate
  notify(ID, log),
  ?debug("~p: log", [ID]),
  ?increment([sessions, log]);
eval(commit, #session{id=ID, computation=C, mode=M} = Session) ->
  State0 = meshup_endpoint:state(C),
  State  = ?time([internal, await], meshup_state:await(State0)), %promises
  case ?time([internal, write], meshup_state:write(State, ID, M)) of
    {ok, _} ->
      ok = put([committed, ID], Session), %may create siblings
      notify(ID, commit),
      ?debug("~p: commit", [ID]),
      ?increment([sessions, commit]);
    {error, Rsn} = Err ->
      ?error("~p: failed to commit: ~p", [ID, Rsn]),
      ?increment([sessions, commit_fail]),
      throw(Err)
  end;
eval(cleanup, #session{id=ID}) ->
  ok = del([wal, ID]),
  notify(ID, cleanup),
  ?debug("~p: cleanup", [ID]),
  ?increment([sessions, cleanup]).

%% The session logger tracks each session as it proceeds through the
%% protocol. We call the last step a session managed to execute
%% successfully the commit-state of that session.
notify(ID, Step) ->
  {ok, Logger} = application:get_env(?APP, logger),
  ok           = meshup_logger:log(Logger, ID, Step).

%% To recover from a crash, we figure out the commit-state each
%% session is in, then re-apply the ops necessary to finish the
%% protocol.
%% Note that the logger must ensure that redo-ing doesn't interfere
%% with currently executing sessions (e.g. using timeouts).

%%   From
redo(prepare, ID) -> S = new(ID, '', '', ''), eval(cleanup, S);
redo(log,     ID) -> {ok, S} = get([wal, ID]), eval([commit, cleanup], S);
redo(commit,  ID) -> S = new(ID, '', '', ''), eval(cleanup, S);
redo(cleanup, _)  -> ok.

%% We provide some functions to facilitate log-replay...
initial_state() -> prepare.

%%    State0   Step        State
state(prepare, log)     -> log;
state(prepare, cleanup) -> cleanup;
state(log,     commit)  -> commit;
state(commit,  cleanup) -> cleanup.

%% ... and log-GC.
is_halting_state(cleanup) -> true;
is_halting_state(_)       -> false.

%% For this protocol to work, writes must be idempotent.
%% We use a generic deep-equality resolver to handle create/create
%% conflicts due to replays. For update conflicts, we rely on
%% application-specific resolvers.


%% If the session log is lost, we manually commit all entries the
%% affected node made in the replicated write-ahead log, i.e. we
%% conservatively assume that everything in the WAL is in commit-state
%% LOG.
%% This may lead to sessions being committed which should have been
%% cleaned up, depending on the session store (in distributed key/value
%% stores, such as, for example, Riak, writes may fail but still show
%% up in the database (somewhat unintuitively); so we might end up
%% committing a session which we reported as failed to the client).

-spec salvage(node()) -> maybe({[_], [_]}, _).
%% @doc Re-apply WAL entries indiscriminantly.
salvage(Node) ->
  ?info("salvaging ~p", [Node]),
  ?increment([salvaged]),
  {ok, Sessions} = ?time([internal, scan, wal], get(wal)),
  [redo(log, S#session.id) || S <- Sessions, originated_on(S, Node)],
  ok.

%%%_ * cancel/1 --------------------------------------------------------
cancel(#session{id=ID} = Session) -> put([cancelled, ID], Session).

%%%_ * Primitives ------------------------------------------------------
%% Session store
put(Key, Val) ->
  {ok, Store} = application:get_env(?APP, store),
  meshup_store:put_(Store, Key, Val).

del(Key) ->
  {ok, Store} = application:get_env(?APP, store),
  meshup_store:del(Store, Key).

get(Key) ->
  {ok, Store} = application:get_env(?APP, store),
  meshup_store:get_(Store, Key).

%%%_* Tests ============================================================
-ifdef(TEST).

session() ->
  new(fresh_id(),
      meshup_endpoint:eval(
        meshup_endpoint:make(
          ?thunk([{meshup_test_services:nop(), nop}]))),
      in_process, false).


persist_test() ->
  meshup_test:with_env(fun() ->
    S                 = session(),
    ID                = id(S),
    true              = is_mode(mode(S)),
    _                 = computation(S),
    {ok, _}           = persist(S),
    {error, notfound} = get([wal, ID]),
    {ok, S}           = get([committed, ID])
  end).

cancel_test() ->
  meshup_test:with_env(fun() ->
    S                 = session(),
    ID                = id(S),
    ok                = cancel(S),
    {error, notfound} = get([wal, ID]),
    {ok, S}           = get([cancelled, ID])
  end).

continuation_test() ->
  meshup_test:with_env(fun() ->
    S                 = session(),
    ID                = id(S),
    {error, notfound} = inspect(ID),
    {error, notfound} = load(ID),
    ok                = save(S),
    {ok, S}           = load(ID),
    ok                = save(S),
    ok                = collect(),
    {ok, S}           = load(ID),
    ok                = save(S),
    ok                = timer:sleep(11),
    ok                = collect(10),
    {error, notfound} = load(ID),
    {ok, S}           = get([stale, ID])
  end).

recovery_test() ->
  meshup_test:with_env(fun() ->
    S                 = session(),
    ID                = id(S),

    ok                = eval([prepare, log], S),
    {ok, S}           = get([wal, ID]),
    ok                = redo(prepare, S#session.id),
    {error, notfound} = get([wal, ID]),

    ok                = eval([prepare, log, commit], S),
    {ok, S}           = get([wal, ID]),
    ok                = redo(commit, S#session.id),
    {error, notfound} = get([wal, ID]),

    ok                = eval([prepare, log, commit, cleanup], S),
    {error, notfound} = get([wal, ID]),
    ok                = redo(cleanup, S#session.id),

    S2                = (session())#session{node=quux},
    ID2               = id(S2),
    ok                = put([wal, ID2], S2),
    ok                = eval([prepare, log], S),
    {ok, S}           = get([wal, ID]),
    ok                = salvage(node()),
    {error, notfound} = get([wal, ID]),
    {ok, S2}          = get([wal, ID2]),

    %% Cover
    false             = is_halting_state(initial_state()),
    true              = is_halting_state(cleanup),
    log               = state(prepare, log),
    commit            = state(log, commit),
    cleanup           = state(commit, cleanup)
  end).

logger_test() ->
  meshup_test:with_env(fun() ->
    {ok, Logger} = application:get_env(?APP, logger),
    []           = meshup_logger:redo(Logger)
  end).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
