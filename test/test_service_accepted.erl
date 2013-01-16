%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Mock consistency checker.
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
-module(test_service_accepted).
-behaviour(meshup_service).

%%%_* Exports ==========================================================
-export([ call/2
        , describe/2
        , name/0
        , props/1
        , sla/1
        ]).

%%%_* Includes =========================================================
%%-include_lib("").

%%%_* Code =============================================================
call(finalize_purchase, Ctx) ->
  meshup:ok([[accepted, purchase], make_purchase(Ctx)]).

make_purchase(Ctx) ->
  { meshup_contexts:get(Ctx, [checkout, goods])
  , meshup_contexts:get(Ctx, [id, customer])
  , meshup_contexts:get(Ctx, [risk, score])
  }.

describe(finalize_purchase, input) ->
  [ [checkout, goods]
  , [id, customer]
  , [risk, score]
  ];
describe(finalize_purchase, output) ->
  {ok, Store} = application:get_env(meshup, store),
  [ {[accepted,purchase], [ {store, Store}
                          ]}
  ].

name()                   -> accepted.
props(finalize_purchase) -> [].
sla(finalize_purchase)   -> 10.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
