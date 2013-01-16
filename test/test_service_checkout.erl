%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Mock checkout.
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
-module(test_service_checkout).
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
call(query_customer, Ctx) ->
  InGoods = meshup_contexts:get(Ctx, [input, goods]),
  OutCtx  = meshup_contexts:new([[checkout, goods], InGoods]),
  case meshup_contexts:get(Ctx, [id, suggestion], undefined) of
    undefined ->
      meshup:ok(OutCtx);
    email ->
      case meshup_contexts:get(Ctx, [input, email], undefined) of
        undefined -> meshup:error(block);
        Email     -> meshup:ok(meshup_contexts:set(OutCtx,
                                                   [checkout,email],
                                                   Email))
      end
  end.

describe(query_customer, input) ->
  [ [input, goods]
  , {[input, email], [{optional,true}]}
  , {[id, suggestion], [{optional,true}]}
  ];
describe(query_customer, output) ->
  [ [checkout, goods]
  , {[checkout,email], [{optional,true}]}
  ].

name()                -> checkout.
props(query_customer) -> [].
sla(query_customer)   -> 10.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
