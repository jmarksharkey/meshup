%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Mock risk service.
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
-module(test_service_risk).
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
call(score_customer, Ctx) ->
  _ = meshup_contexts:get(Ctx, [id, customer]),
  meshup:ok([[risk, score], 42]).

describe(score_customer, input)  -> [ [id, customer] ];
describe(score_customer, output) -> [ [risk, score]  ].

name()                -> risk.
props(score_customer) -> [].
sla(score_customer)   -> 10.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
