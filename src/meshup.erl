%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc The MeshUp service-orchestration engine.
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
-module(meshup).

%%%_* Exports ==========================================================
-export([ finish/1
        , resume/1
        , start/1
        ]).

-export([ inspect/1
        , is_session/1
        ]).

-export([ ok/1
        , error/1
        , error/2
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("meshup/include/test.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/logging.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

-include("shared.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
%% Abbrevs
-type cb()         :: meshup_callbacks:callback().
-type ctx()        :: meshup_contexts:context().
-type rsn()        :: meshup_service:reason().
-type mode()       :: meshup_sessions:mode().
-type session_id() :: meshup_sessions:id().

%% Options
-type opts()       :: [opt()].
-type opt()        :: {endpoint,   cb()}
                    | {input,      ctx()}
                    | {label,      atom()}
                    | {session_id, session_id()}
                    | {timeout,    timeout()}
                    | {mode,       mode()}
                    | {compress,   boolean()}.

%% Service returns
-type content()    :: ctx()
                    | meshup_contexts:literal().
-type return()   :: #return{}. %shared.hrl

%% Workflow status upon successful return of an API function.
-type status()     :: {suspended, session_id(), ctx()}
                    | {committed, ctx()}.


is_opts(Xs)             -> lists:all(fun is_opt/1, Xs).
is_opt({endpoint,   E}) -> meshup_callbacks:is_callback(E);
is_opt({input,      I}) -> meshup_contexts:is_context(I);
is_opt({label,      L}) -> is_atom(L);
is_opt({session_id, _}) -> true;
is_opt({timeout,    T}) -> is_integer(T) andalso T >= 0;
is_opt({mode,       M}) -> meshup_sessions:is_mode(M);
is_opt({compress,   C}) -> is_boolean(C).

%%%_ * start -----------------------------------------------------------
-spec start(opts()) -> maybe(status(), _).
%% @doc Evaluate an endpoint.
%% Returns either a session ID, indicating that the session is blocked
%% waiting for input, or the result of the workflow. In the latter case
%% we guarantee that all data items with store annotations will be
%% written to stable storage.
start(Opts) ->
  ?hence(is_opts(Opts)),
  {ok, Ep} = tulib_lists:assoc(endpoint,   Opts),
  Label    = tulib_lists:assoc(label,      Opts, undefined),
  Input0   = tulib_lists:assoc(input,      Opts, meshup_contexts:new()),
  ID       = tulib_lists:assoc(session_id, Opts, meshup_sessions:fresh_id()),
  Timeout  = tulib_util:get_arg(timeout,  Opts, infinity, ?APP),
  Mode     = tulib_util:get_arg(mode,     Opts, async,    ?APP),
  Compress = tulib_util:get_arg(compress, Opts, false,    ?APP),
  Input    = meshup_flow:annotate(Input0, Label),
  ?info("~p: starting session: ~p: ~p", [ID, Ep, Label]),
  ?increment([sessions, started]),
  do_start(Ep, Input, ID, Timeout, Mode, Compress).

%%%_ * resume ----------------------------------------------------------
-spec resume(opts()) -> maybe(status(), _).
%% @doc Resume a suspended session.
resume(Opts) ->
  ?hence(is_opts(Opts)),
  Label    = tulib_lists:assoc(label,      Opts, undefined),
  Input0   = tulib_lists:assoc(input,      Opts, meshup_contexts:new()),
  {ok, ID} = tulib_lists:assoc(session_id, Opts),
  Timeout  = tulib_util:get_arg(timeout,  Opts, infinity, ?APP),
  Mode     = tulib_util:get_arg(mode,     Opts, async,    ?APP),
  Compress = tulib_util:get_arg(compress, Opts, false,    ?APP),
  Input    = meshup_flow:annotate(Input0, Label),
  ?info("~p: resuming session: ~p", [ID, Label]),
  ?increment([sessions, resumed]),
  tulib_maybe:lift_with(
    meshup_sessions:load(ID),
    fun(Session) ->
      do_start(meshup_sessions:computation(Session),
               Input,
               ID,
               Timeout,
               Mode,
               Compress)
    end).

%%%_ * finish ----------------------------------------------------------
-spec finish(opts()) -> maybe(status(), _).
%% @doc Commit a suspended session.
finish(Opts) ->
  ?hence(is_opts(Opts)),
  {ok, ID} = tulib_lists:assoc(session_id, Opts),
  Timeout  = tulib_util:get_arg(timeout,  Opts, infinity, ?APP),
  Mode     = tulib_util:get_arg(mode,     Opts, async,    ?APP),
  Compress = tulib_util:get_arg(compress, Opts, false,    ?APP),
  Input    = meshup_flow:annotate(meshup_contexts:new(), eof),
  ?info("~p: finishing session", [ID]),
  ?increment([sessions, finished]),
  tulib_maybe:lift_with(
    meshup_sessions:load(ID),
    fun(Session) ->
      do_start(meshup_sessions:computation(Session),
               Input,
               ID,
               Timeout,
               Mode,
               Compress)
    end).

%%%_ * inspect ---------------------------------------------------------
-spec inspect(session_id()) -> maybe(ctx(), _).
%% @doc Return the current context of a suspended session.
inspect(ID) ->
  ?info("~p: inspecting session", [ID]),
  ?increment([sessions, inspected]),
  tulib_maybe:lift_with(
    meshup_sessions:inspect(ID),
    fun(Session) ->
      meshup_endpoint:context(meshup_sessions:computation(Session))
    end).


%%%_ * is_session ------------------------------------------------------
-spec is_session(session_id()) -> boolean().
%%@ doc Return true iff there is a suspended session ID.
is_session(ID) -> tulib_maybe:to_bool(meshup_sessions:inspect(ID)).

%%%_ * ok, error -------------------------------------------------------
-spec ok(content()) -> return().
ok(Ctx) ->
  case meshup_contexts:is_context(Ctx) of
    true  -> #return{type=ok, ctx=Ctx};
    false -> #return{type=ok, ctx=meshup_contexts:new(Ctx)}
  end.

-spec error(rsn()) -> return().
error(Rsn) when is_atom(Rsn) -> #return{type=error, rsn=Rsn}.

-spec error(rsn(), content()) -> return().
error(Rsn, Ctx) when is_atom(Rsn) ->
  case meshup_contexts:is_context(Ctx) of
    true  -> #return{type=error, rsn=Rsn, ctx=Ctx};
    false -> #return{type=error, rsn=Rsn, ctx=meshup_contexts:new(Ctx)}
  end.

%%%_ * Internals -------------------------------------------------------
do_start(Workflow, Input, ID, Timeout, Mode, Compress) ->
  case
    ?time([internal, eval],
          meshup_lib:call_within(
            ?thunk(meshup_endpoint:eval(Workflow, Input)),
            Timeout))
  of
    {error, timeout} = Err ->
      ?warning("~p: meshup timed out", [ID]),
      ?increment([internal, timeouts]),
      Err;
    {error, Rsn} = Err ->
      ?warning("~p: meshup crashed: ~p", [ID, Rsn]),
      ?increment([internal, crashes]),
      Err;
    {ok, Computation} -> finalize(ID, Computation, Mode, Compress)
  end.

finalize(ID, Computation, Mode, Compress) ->
  ?debug("~p: finalizing session: ~s", [ID, meshup_endpoint:pp(Computation)]),
  Session = meshup_sessions:new(ID, Computation, Mode, Compress),
  Hooks   = meshup_endpoint:hooks(Computation), %FIXME
  Context = meshup_endpoint:context(Computation),
  case meshup_endpoint:status(Computation) of
    ?halted ->
      ?info("~p: session halted", [ID]),
      ?increment([sessions, halted]),
      {ok, _} = meshup_sessions:persist(Session),
      _ = run_hooks(Hooks, {ok, Context}), %FIXME
      {ok, {committed, Context}};
    ?suspended ->
      ?info("~p: session suspended", [ID]),
      ?increment([sessions, suspended]),
      ok = meshup_sessions:save(Session),
      {ok, {suspended, ID, Context}};
    {?aborted, Rsn} ->
      ?info("~p: session aborted: ~p", [ID, Rsn]),
      ?increment([sessions, aborted]),
      ok = meshup_sessions:cancel(Session),
      _ = run_hooks(Hooks, {error, {Rsn, Context}}), %FIXME
      {error, {Rsn, Context}};
    {?crashed, Rsn} ->
      ?info("~p: session crashed: ~p", [ID, Rsn]),
      ?increment([sessions, crashed]),
      ok = meshup_sessions:cancel(Session),
      _ = run_hooks(Hooks, {error, {Rsn, Context}}), %FIXME
      {error, {Rsn, Context}};
    {?timeout, {_ServiceName, _Method} = Call} ->
      ?info("~p: call timeout: ~p", [ID, Call]),
      ?increment([sessions, timeouts]),
      ?increment([sessions, _ServiceName, _Method, timeouts]),
      ok = meshup_sessions:cancel(Session),
      _ = run_hooks(Hooks, {error, {timeout, Context}}), %FIXME
      {error, {timeout, Context}}
  end.

%% FIXME
run_hooks(Hooks, Context) ->
  %% XXX: time
  [proc_lib:spawn(?thunk(
    case ?lift(F(Context)) of
      {ok, _} ->
        ?increment([hooks, ok]),
        ok;
      {error, Rsn} ->
        ?increment([hooks, error]),
        ?error("post commit hook crash: ~p: ~p: ~p", [F, Context, Rsn])
    end)) || F <- Hooks],
  ok.

%%%_* Tests ============================================================
-ifdef(TEST).

%%%_ * Basics ----------------------------------------------------------
%% C.f. the callback modules in test/
basic_test() ->
  meshup_test:with_env(?thunk(
    %% 1) Checkout service gets called with goods - initial input
    %%    provided by some external source.
    %% 2) Checkout service passes input on, since the context contains
    %%    no suggestions at this stage.
    %% 3) There's no email in the context so the ID service adds a
    %%    suggestion and returns an error.
    %% 4) The checkout service handles the error by blocking and
    %%    indicating that it needs further input via its return value.
    {ok, {suspended, ID, Ctx0}} =
      start([ {endpoint, test_endpoint}
            , {input,    test_input1()}
            , {compress, true}
            ]),
    true       = is_session(ID),
    {ok, Ctx0} = inspect(ID),
    %% 5) The computation is restarted with additional input.
    %% 6) The checkout service doesn't do anyting.
    %% 7) The ID service matches a customer based on email.
    %% 8) The risk service assigns a score to the matched customer.
    %% 9) The acceptance service creates a purchase from the context.
    %% 10) The purchase is written to a datastore, and an OK is
    %%     returned to the caller.
    {ok, {committed, Ctx}} =
      resume([ {session_id, ID}
             , {input,      test_input2()}
             ]),
    Purchase       = meshup_contexts:get(Ctx, [accepted, purchase]),
    ok             = timer:sleep(10), %async commit
    {ok, Store}    = application:get_env(?APP, store),
    {ok, Purchase} = meshup_store:get(Store, [accepted, purchase]),
    ok
  )).

test_input1() -> ?ctx([[input, goods], [stuff, more_stuff]]).
test_input2() -> ?ctx([[input, email], "foo@bar.baz"]).

%%%_ * Sessions --------------------------------------------------------
%%%_  * Manual ---------------------------------------------------------
%% Suspend/resume with looping.
manual_sessions_test() ->
  meshup_test:with_env(?thunk(
    ID = init(),
    ID = js_refine(ID, 1),
    ID = srv_refine(ID, 42),
    ID = js_refine(ID, 10),
    ID = srv_refine(ID, 666),
    ok = finalize(ID)
  )).

%% Fictional API on top of meshup:start/1 and meshup:resume/1.
init() ->
  {ok, {suspended, ID, _}} =
    start([ {endpoint, loopy_endpoint()}
          , {input,    ?ctx([[input, loop], true])}
          ]),
  ID.

js_refine(ID, Arg)  ->
  {ok, {suspended, ID, _}} =
    resume([ {session_id, ID}
           , {input,      ?ctx([ [input, caller],  js
                               , [input, js, arg], Arg
                               ])}
           ]),
  ID.

srv_refine(ID, Arg) ->
  {ok, {suspended, ID, _}} =
    resume([ {session_id, ID}
           , {input,      ?ctx([ [input, caller],   srv
                               , [input, srv, arg], Arg
                               ])}
           ]),
  ID.

finalize(ID) ->
  InCtx = ?ctx([ [input, caller], none
               , [input, loop],   false
               ]),
  {ok, {committed, OutCtx}} =
    resume([ {session_id, ID}
           , {input, InCtx}
           ]),
  11  = meshup_contexts:get(OutCtx, [loopy, js,  res]),
  667 = meshup_contexts:get(OutCtx, [loopy, srv, res]),
  ok.

%% Implementation.
loopy_endpoint() ->
  Srvc = loopy_service(),
  meshup_endpoint:make(?thunk(
    [ {Srvc, init}
    , {Srvc, refine}, [block, '=>', {}]
    , {Srvc, refine_js}
    , {Srvc, refine_srv}
    , {Srvc, loop}, [loop, '<-', {loopy, refine}]
    ])).

loopy_service() ->
  meshup_service:make(
    %% call/2
    fun(init,       _)   -> nop();
       (refine,     Ctx) -> maybe(fun block_p/1,    Ctx, fun block/1);
       (refine_js,  Ctx) -> maybe(fun js_call_p/1,  Ctx, fun do_js_call/1);
       (refine_srv, Ctx) -> maybe(fun srv_call_p/1, Ctx, fun do_srv_call/1);
       (loop,       Ctx) -> maybe(fun loop_p/1,     Ctx, fun loop/1)
    end,
    %% describe/2
    fun(init,       input)  -> [];
       (init,       output) -> [];

       (refine,     input)  -> [{[loopy, block], [{optional, true}]}];
       (refine,     output) -> [{[loopy, block], [{optional, true}]}];

       (refine_js,  input)  -> [ [input, caller]
                               , {[input, js, arg], [{optional, true}]}
                               ];
       (refine_js,  output) -> [ {[loopy, js, res], [{optional, true}]}
                               ];
       (refine_srv, input)  -> [ [input, caller]
                               , {[input, srv, arg], [{optional, true}]}
                               ];
       (refine_srv, output) -> [ {[loopy, srv, res], [{optional, true}]}
                               ];

       (loop,       input)  -> [[input, loop]];
       (loop,       output) -> [{[loopy, block], [{optional, true}]}
                               ]
    end,
    fun()  -> loopy    end, %name/0
    fun(_) -> []       end, %props/1
    fun(_) -> infinity end  %sla/1
   ).

%% Dispatch, blocking, and looping by hand:
maybe(Pred, Ctx, Fun) ->
  case Pred(Ctx) of
    true  -> Fun(Ctx);
    false -> nop()
  end.

block_p(Ctx)     -> meshup_contexts:get(Ctx, [loopy, block], true).
block(_)         -> meshup:error(block, [[loopy, block], false]).
loop_p(Ctx)      -> meshup_contexts:get(Ctx, [input, loop]).
loop(_)          -> meshup:error(loop, [[loopy, block], true]).

js_call_p(Ctx)   -> js  =:= meshup_contexts:get(Ctx, [input, caller]).
srv_call_p(Ctx)  -> srv =:= meshup_contexts:get(Ctx, [input, caller]).

%%%_  * FoF ------------------------------------------------------------
%% Suspend/resume with looping, the flows of flows version.
%% Note use of finish/1.
fof_sessions_test() ->
  meshup_test:with_env(?thunk(
    ID = init_fof(),
    ID = js_refine_fof(ID, 1),
    ID = srv_refine_fof(ID, 42),
    ID = js_refine_fof(ID, 10),
    ID = srv_refine_fof(ID, 666),
    ok = finalize_fof(ID)
  )).

%% API v2.
init_fof() ->
  {ok, {suspended, ID, _}} =
    start([ {endpoint, loopy_fof_endpoint()}
          , {input,    ?ctx([])}
          , {label,    ini}
          ]),
  ID.

js_refine_fof(ID, Arg) ->
  {ok, {suspended, ID, _}} =
    resume([ {session_id, ID}
           , {input,      ?ctx([[input, js, arg], Arg])}
           , {label,      js}
           ]),
  ID.

srv_refine_fof(ID, Arg) ->
  {ok, {suspended, ID, _}} =
    resume([ {session_id, ID}
           , {input,      ?ctx([[input, srv, arg], Arg])}
           , {label,      srv}
           ]),
  ID.

finalize_fof(ID) ->
  {ok, {committed, OutCtx}} = finish([{session_id, ID}]),
  11                        = meshup_contexts:get(OutCtx, [loopy, js,  res]),
  667                       = meshup_contexts:get(OutCtx, [loopy, srv, res]),
  ok.

%% Implementation v2.
loopy_fof_endpoint() ->
  Srvc = loopy_fof_service(),
  meshup_endpoint:make(?thunk(
    [ ini
    , [{Srvc, init}]
    , js
    , [{Srvc, refine_js}]
    , srv
    , [{Srvc, refine_srv}]
    ])).

loopy_fof_service() ->
  meshup_service:make(
    %% call/2
    fun(init,       _Ctx) -> nop();
       (refine_js,  Ctx)  -> do_js_call(Ctx);
       (refine_srv, Ctx)  -> do_srv_call(Ctx)
    end,
    %% describe/2
    fun(init,       input)  -> [];
       (init,       output) -> [];

       (refine_js,  input)  -> [[input, js, arg]];
       (refine_js,  output) -> [[loopy, js, res]];
       (refine_srv, input)  -> [[input, srv, arg]];
       (refine_srv, output) -> [[loopy, srv, res]]
    end,
    fun()  -> loopy    end, %name/0
    fun(_) -> []       end, %props/1
    fun(_) -> infinity end  %sla/1
   ).

%%%_  * Utilities ------------------------------------------------------
nop()            -> meshup:ok([]).

do_js_call(Ctx)  -> meshup:ok([[loopy,js,res],  inc(Ctx, [input,js,arg])]).
do_srv_call(Ctx) -> meshup:ok([[loopy,srv,res], inc(Ctx, [input,srv,arg])]).

inc(Ctx, Name)   -> meshup_contexts:get(Ctx, Name) + 1.

%%%_ * Errors ----------------------------------------------------------
meshup_crash_test() ->
  ?flowReturns([ {meshup_test_services:read([foo, bar], baz), read}
               ],
               {error, {lifted_exn, _, _}}).

meshup_timeout_test() ->
  ?flowReturns([ {meshup_test_services:read([foo, bar], baz), read}
               ],
               [{timeout, 0}],
               {error, timeout}).

service_abort_test() ->
  ?flowReturns([ {meshup_test_services:guard(true,  foo), guard}
               , {meshup_test_services:guard(false, bar), guard}
               , {meshup_test_services:guard(true,  baz), guard}
               ],
               {error, {bar, _Ctx}}).

service_fof_abort_test() ->
  ?flowReturns([ flow
               , [ {meshup_test_services:guard(true,  foo), guard}
                 , {meshup_test_services:guard(false, bar), guard}
                 , {meshup_test_services:guard(true,  baz), guard}
                 ]
               ],
               [{label, flow}],
               {error, {bar, _Ctx}}).

service_crash_test() ->
  ?flowReturns([ {meshup_test_services:crash(exn), crash}
               ],
               {error, {{lifted_exn, exn, _}, _Ctx}}).

service_timeout_test() ->
  ?flowReturns([ {meshup_test_services:timeout(), timeout}
               ],
               {error, {timeout, _Ctx}}).

%%%_ * Hooks -----------------------------------------------------------
post_commit_hook_ok_test() ->
  ?endpointReturns(hook_endpoint([{meshup_test_services:nop(), nop}]),
                   {ok, _}).

post_commit_hook_error_test() ->
  ?endpointReturns(hook_endpoint([{meshup_test_services:crash(exn), crash}]),
                   {error, _}).

hook_endpoint(Flow) ->
  meshup_endpoint:make(?thunk(Flow), ?thunk([fun hook/1])).

hook({ok, _Ctx} = Ok)      -> Ok;
hook({error, {_Ctx, Rsn}}) -> {error, Rsn}.

%%%_ * Modes -----------------------------------------------------------
async_commit_test() ->
  ?flowReturns([ {meshup_test_services:nop(), nop}
               ],
               [{mode, async}],
               {ok, _}).

in_process_commit_test() ->
  ?flowReturns([ {meshup_test_services:nop(), nop}
               ],
               [{mode, in_process}],
               {ok, _}).

write_set_commit_test() ->
  ?flowReturns([ {write_set_service(), write}
               ],
               [{mode, write_set}],
               {ok, _},
               ?thunk({ok, Store} = application:get_env(?APP, store),
                      {ok, KVs}   = meshup_store:get(Store, write_set),
                      true        = lists:member({[wss,b1,k1], 42}, KVs),
                      true        = lists:member({[wss,b2,k2], 666}, KVs),
                      2           = length(KVs))
              ).

write_set_service() ->
  {ok, Store} = application:get_env(?APP, store),
  meshup_service:make(
    fun(write, _) ->
      meshup:ok(
        [ [wss, b1, k1], 42
        , [wss, b2, k2], 666
        ])
    end,
    fun(write, input)  -> [ ];
       (write, output) -> [ {[wss, b1, k1], [{store, Store}]}
                          , {[wss, b2, k2], [{store, Store}]}
                          ]
    end,
    fun()  -> wss end
   ).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
