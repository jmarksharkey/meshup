%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Storage capabilities.
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
%% @private
-module(meshup_caps).

%%%_* Exports ==========================================================
-export([ is_capability/1
        , new/1
        , new/3
        , revoke/1
        , use/2
        ]).

-export_type([ capability/0
             , guard/0
             , action/0
             , state/0
             ]).

%% Internal exports
-export([ capability/1
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").


%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type msg()                                  :: {use, _}
                                              | revoke.
-record(cap, {ability                        :: fun((msg()) -> maybe(_, _))}).
-opaque capability()                         :: #cap{}.

-record(capability,
        { guard=throw('#capability.guard')   :: guard()
        , action=throw('#capability.action') :: action()
        , state=throw('#capability.state')   :: state()
        , parent=throw('#capability.parent') :: {reference(), pid()}
        }).

-type guard()                                :: fun((state()) -> boolean()).
-type action()                               :: fun((_) -> maybe(_, _))
                                              | fun((_, state()) ->
                                                       {state(), maybe(_, _)}).
-type state()                                :: _.

%%%_ * API -------------------------------------------------------------
-spec new(action()) -> capability().
%% @doc Construct a new capability owned by the calling process.
%%
%% Action is a function which grants controlled access to a side effect
%% of some sort.
%% Optionally, a Guard function and an initial State may be provided to
%% enforce dynamic access restrictions:
%% `use' requests will be serviced iff the Guard returns true when
%% applied to the current state; in this case the Action must return an
%% updated state in addition to the return value of the operation.
%%
%% A capability may be copied to delegate authority to other processes.
%% Only the owner may `revoke' a capability and all capabilities owned
%% by a process are automatically revoked when that process exits.
new(Action) ->
  new(fun('') -> true end, fun(Args, '') -> {'', Action(Args)} end, '').

-spec new(guard(), action(), _) -> capability().
new(Guard, Action, State) ->
  Self = self(),
  Pid  = do_new(Guard, Action, State, Self),
  #cap{ability=fun({use, _} = X) -> call(Pid, X);
                  (revoke = X)   -> call(Pid, X);
                  (X)            -> throw({badmsg, X})
               end}.

-spec is_capability(_) -> boolean().
%% @doc Returns true iff X is a capability.
is_capability(#cap{})  -> true;
is_capability(_)       -> false.

-spec revoke(capability()) -> maybe(_, _).
%% @doc Revoke Cap. All future `use' requests will fail.
revoke(#cap{ability=C})    -> C(revoke).

-spec use(capability(), _) -> maybe(_, _).
%% @doc Apply the operation encapsulated by Cap to Args.
use(#cap{ability=C}, Args) -> C({use, Args}).

%%%_ * Internals -------------------------------------------------------
do_new(G, A, S, P) ->
  proc_lib:spawn(?thunk(
    capability(#capability{ guard  = G
                          , action = A
                          , state  = S
                          , parent = {erlang:monitor(process, P), P}
                          }))).

capability(#capability{guard=G, action=A, state=S0, parent={M, P}} = C) ->
  receive
    {Pid, {use, Args}} ->
      {S, Ret} = do_use(Args, G, A, S0),
      ok       = tulib_processes:send(Pid, Ret),
      ?MODULE:capability(C#capability{state=S});
    {P, revoke} ->
      ok = tulib_processes:send(P, {ok, revoked}); %exit
    {Pid, revoke} ->
      ok = tulib_processes:send(Pid, {error, auth}),
      ?MODULE:capability(C);
    {'DOWN', M, process, P, _Rsn} ->
      ok %revoke
  end.

do_use(Args, G, A, S0) ->
  case do_read1(Args, G, A, S0) of
    {ok, {S, Ret}}   -> {S,  Ret};
    {error, _} = Err -> {S0, Err}
  end.

do_read1(Args, G, A, S0) ->
  case ?lift(G(S0)) of
    {ok, true}       -> ?lift(A(Args, S0));
    {ok, false}      -> {error, guard};
    {error, _} = Err -> Err
  end.


call(Pid, Msg) ->
  tulib_processes:with_monitor(Pid, fun(Proc) ->
    tulib_processes:send(Proc, Msg),
    case tulib_processes:recv(Proc) of
      {ok, Ret}             -> Ret;
      {error, {down, _Rsn}} -> {error, revoked}
    end
  end).

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  Tab  = tab(),
  Cap  = new(fun(Key) -> ets:lookup(Tab, Key) end),
  [ {ok, [{foo, 0}]}
  , {ok, [{bar, 1}]}
  , {ok, [{foo, 0}]}
  , {ok, [{bar, 1}]}
  ]    = [use(Cap, X) || X <- [foo, bar, foo, bar]],
  ok.

quota_test() ->
  Cap              = cap(),
  Pid              = pid(),
  Code             = ?thunk([use(Cap, X) || X <- [foo, bar]]),
  {ok, [{foo, 0}]} = use(Cap, foo),
  ok               = tulib_processes:send(Pid, Code),
  {ok, Ret}        = tulib_processes:recv(Pid),
  [ {ok, [{foo, 0}]}
  , {error, guard}
  ]                = Ret,
  ok.

revoke_test() ->
  Cap             = cap(),
  Pid             = pid(),
  Code            = ?thunk([begin
                              Y = use(Cap, X),
                              timer:sleep(20),
                              Y
                            end || X <- [foo, bar]]),
  ok              = tulib_processes:send(Pid, Code),
  ok              = timer:sleep(10),
  {ok, revoked}   = revoke(Cap),
  {ok, Ret}       = tulib_processes:recv(Pid),
  [ {ok, [{foo, 0}]}
  , {error, revoked}
  ]               = Ret,
  ok.

auth_test() ->
  Cap             = cap(),
  Pid             = pid(),
  Code            = ?thunk(revoke(Cap)),
  ok              = tulib_processes:send(Pid, Code),
  {ok, Ret}       = tulib_processes:recv(Pid),
  {error, auth}   = Ret,
  ok.

self_revoke_test() ->
  Self             = self(),
  _                = spawn(?thunk(Self ! {cap, cap()},
                                  timer:sleep(10))),
  Cap              = receive {cap, X} -> X end,
  {ok, [{foo, 0}]} = use(Cap, foo),
  timer:sleep(20),
  {error, revoked} = use(Cap, foo),
  ok.

misc_errors_test() ->
  Cap   = cap(),
  true  = is_capability(Cap),
  false = is_capability(''),
  ?assertException(throw, {badmsg, frob}, (Cap#cap.ability)(frob)),

  Guard1    = fun(_)  -> throw(guard) end,
  Action1   = fun(_, _) -> 42 end,
  BuggyCap1 = new(Guard1, Action1, ''),
  {error, {lifted_exn, guard, _}} = use(BuggyCap1, foo),

  Guard2    = fun(_)  -> true end,
  Action2   = fun(_, _) -> throw(action) end,
  BuggyCap2 = new(Guard2, Action2, ''),
  {error, {lifted_exn, action, _}} = use(BuggyCap2, foo),

  ok.


tab() ->
  Tab    = ets:new('', []),
  true   = ets:insert(Tab, [{foo, 0}, {bar, 1}]),
  Tab.

cap() ->
  Tab    = tab(),
  Guard  = fun(N)      -> N < 2                       end,
  Action = fun(Key, N) -> {N+1, ets:lookup(Tab, Key)} end,
  State  = 0,
  new(Guard, Action, State).

pid() -> spawn(fun loop/0).

loop() ->
  receive
    {Pid, F} ->
      ok = tulib_processes:send(Pid, F()),
      loop()
  end.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
