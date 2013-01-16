%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Utility procedures used in MeshUp.
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
-module(meshup_lib).

%%%_* Exports ==========================================================
-export([ call_within/2
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
-spec call_within(fun(), timeout()) -> maybe(_, _).
call_within(Thunk, Timeout) ->
  case
    tulib_par:eval(fun(Thunk) -> Thunk() end,
                   [Thunk],
                   [{errors, false}],
                   Timeout)
  of
    {ok, [Res]}              -> {ok, Res};
    {error, {worker, [Rsn]}} -> {error, Rsn};
    {error, timeout} = Err   -> Err
  end.

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  {ok, 42}                      = call_within(?thunk(42), 10),
  {error, timeout}              = call_within(?thunk(timer:sleep(20), 42), 10),
  {error, {lifted_exn, meh, _}} = call_within(?thunk(throw(meh)), 10),
  {error, foo}                  = call_within(?thunk({error, foo}), 10),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
