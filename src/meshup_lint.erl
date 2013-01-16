%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Endpoint linter.
%%% @todo add support for session flows
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
-module(meshup_lint).

%%%_* Exports ==========================================================
-export([ check/1
        ]).

%%%_* Includes =========================================================
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
%%%_* API --------------------------------------------------------------
-spec check(meshup_callbacks:callback()) -> maybe(_, _).
%% @doc Return `ok' if Endpoint (assumed to compile) might actually
%% compute something.
check(Endpoint) -> ?lift(do_check(meshup_endpoint:flow(Endpoint))).

%%%_* Internals---------------------------------------------------------
-spec do_check(meshup_endpoint:flow()) -> meshup_endpoint:flow() | no_return().
do_check(Flow) ->
  lists:foldl(fun(Step, CurNames) -> do_check(Step, CurNames) end,
              sets:new(),
              [Step || Step <- Flow, meshup_endpoint:is_step(Step)]),
  Flow.

do_check(Step, CurNames) ->
  InNames = get_names(Step, input, fun is_computed/1),
  Missing = sets:subtract(InNames, CurNames),
  sets:size(Missing) =:= 0 orelse
    throw({missing, Step, sets:to_list(Missing)}),
  sets:union(CurNames, get_names(Step, output)).


get_names(Step, Type) ->
  get_names(Step, Type, tulib_combinators:k(true)).
get_names(Step, Type, Pred) ->
  {ok, Contract} = meshup_contracts:parse(Step, Type),
  sets:from_list(
    [Name || {Name, _} = Clause <- meshup_contracts:clauses(Contract),
             Pred(Clause)]).

is_computed({Name, As}) -> not (is_input(Name) orelse
                                is_stored(As)  orelse
                                is_optional(As)).

is_input(Name) -> meshup_contracts:namespace(Name) =:= input.

is_stored(As) ->
  case tulib_lists:assoc(store, As) of
    {ok, _}           -> true;
    {error, notfound} -> false
  end.

is_optional(As) -> tulib_lists:assoc(optional, As, false).

%%%_* Tests ============================================================
-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).

goodflow_test() ->
  meshup_test:with_env(?thunk({ok, _} = check(good_endpoint()))).

good_endpoint() ->
  meshup_endpoint:make(fun() ->
    [ {test_service_checkout, query_customer}

    , {test_service_id, identify_customer}
    , [insufficient_data, '<=', {checkout, query_customer}]

    , {test_service_risk, score_customer}
    , {test_service_accepted, finalize_purchase}
    ] end).


badflow_test() ->
  meshup_test:with_env(?thunk(
    { error
    , { lifted_exn
      , { missing
        , {test_service_risk, score_customer}
        , [[id,customer]]
        }
      , _ST
      }
    } = check(bad_endpoint()),
  ok)).

bad_endpoint() ->
  meshup_endpoint:make(fun() ->
    [ {test_service_checkout, query_customer}
    , [insufficient_data, {checkout, query_customer}]

    , {test_service_risk, score_customer}
    %% ID occurs after risk instead of after checkout, breaking it.
    , {test_service_id, identify_customer}
    , {test_service_accepted, finalize_purchase}
    ] end).


stores_as_inputs_test() -> {ok, _} = check(stores_as_inputs_endpoint()).

stores_as_inputs_endpoint() ->
  meshup_endpoint:make(fun() ->
    [ { meshup_test_services:read([foo,bar], test_store_ets:new())
      , read
      }
    ] end).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
