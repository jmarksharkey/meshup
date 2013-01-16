%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Test-support library.
%%% @copyright 2012 Klarna AB
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
-module(meshup_test).

%%%_* Exports ==========================================================
-export([ flow/3
        , flow/4
        , method/3
        , method/4
        , with_env/1
        ]).

-export_type([ post_condition/0
             , status/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

-include("shared.hrl").

%%%_* Code =============================================================
%%%_ * method/3,4 & flow/3,4 -------------------------------------------
%%%_  * Types ----------------------------------------------------------
-type call()            :: meshup_endpoint:call().
-type flow()            :: meshup_endpoint:flow().
-type context()         :: meshup_contexts:context()
                         | meshup_contexts:literal().
-type post_condition()  :: [name() | pred()].
-type name()            :: meshup_contracts:name().
-type pred()            :: fun((_) -> boolean()).
-type status()          :: halted
                         | suspended
                         | {aborted, _}
                         | {crashed, _}
                         | {timeout, _}.

%%%_  * API ------------------------------------------------------------
-spec method(call(), context(), post_condition(), status()) -> whynot().
method(Call, Ctx, PostCondition) ->
  flow([Call], Ctx, PostCondition).
method(Call, Ctx, PostCondition, Status) ->
  flow([Call], Ctx, PostCondition, Status).

-spec flow(flow(), context(), post_condition(), status()) -> whynot().
flow(Flow, Ctx, PostCondition) ->
  flow(Flow, Ctx, PostCondition, halted).
flow(Flow, Ctx, PostCondition, Status) ->
  do_flow(Flow,
          to_ctx(Ctx),
          to_fun(PostCondition, to_ctx(Ctx)),
          to_status(Status)).

%%%_  * Internals ------------------------------------------------------
to_ctx(Lst) when is_list(Lst) -> meshup_contexts:new(Lst);
to_ctx(Ctx)                   -> Ctx.

to_fun(PostCondition, Input0) ->
  fun(Ctx) ->
    Input = meshup_contexts:to_obj(Input0),
    case
      tulib_maybe:reduce(
        fun({Name, Val}, Obj) ->
          Pred0 = soapbox_obj:get(Obj, Name, fun(_) -> true end),
          Pred  = if is_function(Pred0) -> Pred0;
                     true               -> fun(X) -> X =:= Pred0 end
                  end,
          case Pred(Val) of
            true  -> {ok, soapbox_obj:del(Obj, Name)};
            false -> {error, {Name, Val}}
          end
        end,
        soapbox_obj:from_list(
          PostCondition,
          fun(K, _V) -> meshup_contracts:is_name(K) end),
        meshup_contexts:to_list(Ctx))
    of
      {ok, Obj} ->
        Diff = soapbox_obj:difference(Obj, Input),
        case soapbox_obj:is_empty(Diff) of
          true  -> ok;
          false -> {error, soapbox_obj:keys(Diff)}
        end;
      {error, _} = Err -> Err
    end
  end.

to_status({F, S}) when is_atom(F) -> {to_status(F), S};
to_status(F)      when is_atom(F) -> tulib_atoms:catenate(['__', F, '__']).

do_flow(Flow, Ctx, PostCondition, Status) ->
  Computation0 = meshup_endpoint:init(meshup_endpoint:make(?thunk(Flow)), Ctx),
  Computation  = meshup_endpoint:eval_loop(Computation0),
  case meshup_endpoint:status(Computation) of
    Status -> PostCondition(meshup_endpoint:context(Computation));
    X      -> {error, {status, X}}
  end.

%%%_ * with_env/1 ------------------------------------------------------
with_env(Thunk) -> tulib_util:with_env(meshup, test_env(), Thunk).

test_env() ->
  [ {timeout, 100}
  , {store,   test_store_ets:new()}
  , {logger,  test_logger}
  ].

%%%_* Tests ============================================================
-ifdef(TEST).

srvc() ->
  meshup_service:make(
    fun(method,  _)  -> meshup:ok([ [s,b,k], 42 ]);
       (method2, _)  -> meshup:error(foo)
    end,
    fun(_, input)  -> [[snarf,blarg]];
       (_, output) -> [[s,b,k]]
    end,
    fun() -> s end
    ).


basic_test() ->
  %% Present in post condition and context - true
  %% Present in context but not post condition - input
  ok =
    method({srvc(), method},
           [ [snarf,blarg], quux ],
           [ [s,b,k], fun(X) -> X > 0 end ]),

  %% Present in post condition and context - false
  F = fun(X) -> X =:= 0 end,
  {error, {[s,b,k], 42}} =
    method({srvc(), method},
           [ [snarf,blarg], quux ],
           [ [s,b,k], 0 ]),

  %% Present in context but not post condition
  ok =
    method({srvc(), method},
           [ [snarf,blarg], quux ],
           [ ]),

  %% Present in post condition but not context
  {error, [[s,b,k2]]} =
    method({srvc(), method},
           meshup_contexts:new([ [snarf,blarg], quux ]),
           [ [s,b,k],  fun(X) -> X > 0 end
           , [s,b,k2], F
           ]),
  ok.


pred_test() ->
  %% Status as expected
  ok =
    method({srvc(), method2},
           [ [snarf,blarg], quux ],
           [ ],
           {aborted, foo}),

  %% Status not as expected
  {error, {status, {'__aborted__', foo}}} =
    method({srvc(), method2},
           [ [snarf,blarg], quux ],
           [  ],
           suspended),
  ok.


with_env_test() ->
  with_env(?thunk(ok)).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
