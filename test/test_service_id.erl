%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Mock identification service.
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
-module(test_service_id).
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
call(identify_customer, Ctx) ->
  case meshup_contexts:get(Ctx, [checkout, email], undefined) of
    undefined ->
      meshup:error(insufficient_data, [[id,suggestion], email]);
    Email ->
      [User, _Domain] = string:tokens(Email, "@"),
      meshup:ok([[id,customer], User])
  end.

describe(identify_customer, input) ->
  [ {[checkout, email], [{optional, true}]}
  ];
describe(identify_customer, output) ->
  [ {[id, suggestion], [{optional,true}]}
  , {[id, customer], [{optional,true}]}
  ].

name()                   -> id.
props(identify_customer) -> [].
sla(identify_customer)   -> 10.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
