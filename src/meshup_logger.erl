%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc MeshUp session logger behaviour.
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
-module(meshup_logger).

%%%_* Exports ==========================================================
-export([ behaviour_info/1
        , new/1
        ]).

-export([ log/3
        , redo/1
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Code =============================================================
%%%_ * Behaviour -------------------------------------------------------

%%-callback log(id(), step()) -> maybe(_, _).
%%-callback redo()            -> maybe(_, _).

behaviour_info(callbacks) ->
  [ {log,  2}
  , {redo, 0}
  ];
behaviour_info(_) -> undefined.

new(Mtab) -> meshup_callbacks:new(Mtab, ?MODULE).

log(L, ID, Step) -> meshup_callbacks:call(L, log,     [ID, Step]).
redo(L)          -> meshup_callbacks:call(L, redo,    []).

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  Logger = new(
    [ {log,  2}, fun(_, _) -> ok end
    , {redo, 0}, fun()     -> [] end
    ]),

  ok = log(Logger, 42, prepare),
  [] = redo(Logger),

  ok.

stupid_test() -> _ = behaviour_info(foo).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
