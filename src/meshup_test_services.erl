%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Various small services which provoke specific behaviour.
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
-module(meshup_test_services).

%%%_* Exports ==========================================================
-export([ block/0
        , crash/1
        , guard/2
        , nop/0
        , read/2
        , timeout/0
        , timeout/1
        , write/3
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("tulib/include/prelude.hrl").

-include("shared.hrl").

%%%_* Code =============================================================
%% @doc
block() ->
  meshup_service:make(
    fun(block, Ctx)    -> case ?lift(meshup_contexts:get(Ctx, [block, flag])) of
                            {ok, _}    -> meshup:ok([]);
                            {error, _} -> meshup:error(block, [[block, flag], true])
                          end
    end,
    fun(block, input)  -> [ {[block, flag], [{optional, true}]} ];
       (block, output) -> [ {[block, flag], [{optional, true}]} ]
    end,
    fun() -> block end
    ).

%% @doc Method `crash' raises Exn.
crash(Exn) ->
  meshup_service:make(
    fun(crash, _Ctx)   -> throw(Exn) end,
    fun(crash, input)  -> [];
       (crash, output) -> []
    end,
    fun() -> crash end
    ).

%% @doc Method `guard' returns error(Rsn) iff Guard is false.
%% Guard must reduce to a boolean value.
guard(Guard, Rsn) ->
  meshup_service:make(
    fun(guard, _Ctx) ->
       case tulib_call:reduce(Guard) of
         true  -> meshup:ok([]);
         false -> meshup:error(Rsn)
       end
    end,
    fun(guard, input)  -> [];
       (guard, output) -> []
    end,
    fun() -> guard end
    ).

%% @doc Method `nop' does nothing.
nop() ->
  meshup_service:make(
    fun(nop, _Ctx)   -> meshup:ok([]) end,
    fun(nop, input)  -> [];
       (nop, output) -> []
    end,
    fun() -> nop end
    ).

%% @doc Method `read' reads Key from Store.
read([NS|_] = Key, Store) ->
  meshup_service:make(
    fun(read, Ctx)    -> meshup:ok(Ctx) end,
    fun(read, input)  -> [{Key, [{store, Store}]}];
       (read, output) -> [Key]
    end,
    fun() -> NS end
    ).

%% @doc Method `timeout' times out, or, if a Timeout > 0 is provided,
%% returns error(timeout).
timeout() ->
  timeout(0).
timeout(Timeout) ->
  meshup_service:make(
    fun(timeout, _Ctx)   -> meshup:error(timeout) end,
    fun(timeout, input)  -> [];
       (timeout, output) -> []
    end,
    fun()  -> timeout end,
    fun(_) -> []      end,
    fun(_) -> Timeout end
    ).

%% @doc Method `write' writes Key -> Val to Store.
write([NS|_] = Key, Val, Store) ->
  meshup_service:make(
    fun(write, _Ctx)    -> meshup:ok([Key, Val]) end,
    fun(write, input)  -> [];
       (write, output) -> [{Key, [{store, Store}]}]
    end,
    fun() -> NS end
    ).

%%%_* Tests ============================================================
-ifdef(TEST).

cover_test() ->
  meshup_service:call(read([foo],bar), read, []),
  meshup_service:call(timeout(foo), timeout, ctx),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
