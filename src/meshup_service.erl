%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc The MeshUp service behaviour.
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
-module(meshup_service).

%%%_* Exports ==========================================================
-export([ behaviour_info/1
        , make/3
        , make/5
        , new/1
        ]).

-export([ call/3
        , describe/3
        , name/1
        , props/2
        , sla/2
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Code =============================================================
%% -callback call(method(), context())  -> meshup:return().
%% -callback describe(method(), type()) -> meshup_contracts:declaration().
%% -callback name()                     -> atom().
%% -callback props(method())            -> [_].
%% -callback sla(method())              -> timeout().

behaviour_info(callbacks) ->
  [ {call,     2}
  , {describe, 2}
  , {name,     0}
  , {props,    1}
  , {sla,      1}
  ];
behaviour_info(_) -> undefined.

make(Call, Describe, Name) ->
  make(Call,
       Describe,
       Name,
       fun(_) -> [] end,
       fun(_) -> infinity end).
make(Call, Describe, Name, Props, SLA) ->
  new([ {call,     2}, Call
      , {describe, 2}, Describe
      , {name,     0}, Name
      , {props,    1}, Props
      , {sla,      1}, SLA
      ]).

new(Mtab) -> meshup_callbacks:new(Mtab, ?MODULE).

call(Srvc, API, Ctx)   -> meshup_callbacks:call(Srvc, call,     [API, Ctx]).
describe(Srvc, API, T) -> meshup_callbacks:call(Srvc, describe, [API, T]).
name(Srvc)             -> meshup_callbacks:call(Srvc, name,     []).
props(Srvc, API)       -> meshup_callbacks:call(Srvc, props,    [API]).
sla(Srvc, API)         -> meshup_callbacks:call(Srvc, sla,      [API]).

%%%_* Tests ============================================================
-ifdef(TEST).

mycall(myapi, Ctx)        -> Ctx.
mydescribe(myapi, input)  -> [];
mydescribe(myapi, output) -> [].
myname()                  -> myservice.

myservice() ->
  make(fun mycall/2,
       fun mydescribe/2,
       fun myname/0).

basic_test() ->
  Srvc      = myservice(),
  Ctx       = meshup_contexts:new(),
  Ctx       = call(Srvc, myapi, Ctx),
  []        = describe(Srvc, myapi, input),
  []        = describe(Srvc, myapi, output),
  myservice = name(Srvc),
  []        = props(Srvc, myapi),
  infinity  = sla(Srvc, myapi),
  ok.

stupid_test() -> _ = behaviour_info(frob).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
