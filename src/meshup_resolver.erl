%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Conflict-resolution procedures.
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
-module(meshup_resolver).

%%%_* Exports ==========================================================
%% Behaviour
-export([ behaviour_info/1
        , make/1
        , new/1
        ]).

-export([ resolve/3
        ]).

%% API
-export([ compose/1
        , from_fun/1
        , to_fun/1
        ]).

-export_type([ resolution_procedure/0
             , resolver/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/logging.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type resolution_procedure() :: fun((A, A) -> maybe(A, _)).
-type resolver()             :: meshup_callbacks:callback().

%%%_ * Behaviour -------------------------------------------------------
%% -callback resolve(A, A) -> maybe(A, _).

behaviour_info(callbacks) ->
  [ {resolve, 2}
  ];
behaviour_info(_) -> undefined.

new(Mtab) -> meshup_callbacks:new(Mtab, ?MODULE).

make(F) -> new([{resolve, 2}, F]).

resolve(R, V1, V2) -> meshup_callbacks:call(R, resolve, [V1, V2]).

%%%_ * API -------------------------------------------------------------
-spec compose([resolver()]) -> resolver().
compose([_, _|_] = Rs) ->
  lists:foldl(tulib_combinators:flip(fun compose/2),
              hd(Rs),
              tl(Rs)).

-spec compose(resolver(), resolver()) -> resolver().
compose(R1, R2) ->
  ?hence(meshup_callbacks:is_callback(R1)),
  ?hence(meshup_callbacks:is_callback(R2)),
  new(
    [ {resolve, 2}
    , fun(V1, V2) ->
        case ?lift(resolve(R1, V1, V2)) of
          {ok, _} = Ok ->
            ?info("trying ~p... OK", [meshup_callbacks:name(R1)]),
            Ok;
          {error, _Rsn} ->
            ?info("trying ~p... ERR: ~p", [meshup_callbacks:name(R1), _Rsn]),
            ?info("try ~p", [meshup_callbacks:name(R2)]),
            ?lift(resolve(R2, V1, V2))
        end
      end
    ]).


-spec from_fun(resolution_procedure()) -> resolver().
from_fun(F) -> new([{resolve,2}, fun(V1, V2) -> ?lift(F(V1, V2)) end]).

-spec to_fun(resolver()) -> resolution_procedure().
to_fun(R) -> fun(V1, V2) -> ?lift(resolve(R, V1, V2)) end.

%%%_* Tests ============================================================
-ifdef(TEST).

r1() -> make(fun(foo, bar) -> {ok, bar};
                (_, _)     -> io:format(user, "r1~n", []), {error, r1}
             end).
r2() -> make(fun(foo, foo) -> {ok, foo};
                (_, _)     -> io:format(user, "r2~n", []), {error, r2}
             end).
r3() -> make(fun(foo, foo) -> {ok, bar};
                (_, _)     -> io:format(user, "r3~n", []), {error, r3}
             end).

compose_test() ->
  R           = compose([r1(), r2(), r3()]),
  {ok, foo}   = resolve(R, foo, foo),
  {error, r3} = resolve(R, bar, bar),
  ok.

to_from_fun_test() ->
  R           = r1(),
  F           = to_fun(R),
  {ok, bar}   = F(foo, bar),
  {error, r1} = F(bar, foo),
  _           = from_fun(F),
  ok.

stupid_test() -> _ = behaviour_info(foo).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
