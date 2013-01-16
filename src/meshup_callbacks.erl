%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Dynamic callback objects.
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
-module(meshup_callbacks).

%%%_* Exports ==========================================================
-export([ call/3
        , is_callback/1
        , lookup/2
        , name/1
        , new/2
        ]).

-export_type([ callback/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Code =============================================================
-type callback_module() :: atom().
-type callback_object() :: fun(({atom(), non_neg_integer()}) -> fun()).
-type callback()        :: callback_module() | callback_object().


-spec new([{atom(), non_neg_integer()} | fun()], atom()) -> callback_object().
new(MethodTable0, BehaviourModule) ->
  MethodTable = soapbox_obj:from_list(MethodTable0,
                                      fun({F, A}, Fun) ->
                                        is_atom(F)    andalso
                                        is_integer(A) andalso
                                        is_function(Fun, A)
                                      end),
  true = is_valid(BehaviourModule:behaviour_info(callbacks), MethodTable),
  fun(Callback) -> soapbox_obj:get(MethodTable, Callback) end.

is_valid([First|Rest], MethodTable) ->
  soapbox_obj:get(MethodTable, First, undefined) =/= undefined
    andalso is_valid(Rest, soapbox_obj:del(MethodTable, First));
is_valid([], MethodTable) -> soapbox_obj:is_empty(MethodTable).


-spec call(callback(), atom(), [_]) -> _.
call(Callback, Fun, Args) when is_atom(Callback) ->
  apply(Callback, Fun, Args);
call(Callback, Fun, Args) when is_function(Callback, 1) ->
  apply(Callback({Fun, length(Args)}), Args).


-spec is_callback(_)                      -> boolean().
is_callback(Mod) when is_atom(Mod)        -> true;
%% > is_function({foo, bar}, 42).
%% true
is_callback(Fun) when is_tuple(Fun)       -> false;
is_callback(Obj) when is_function(Obj, 1) -> true;
is_callback(_)                            -> false.


-spec lookup(callback(), {atom(), non_neg_integer()}) -> fun().
lookup(Callback, NameArity) -> Callback(NameArity).


-spec name(callback())          -> atom().
name(Mod) when is_atom(Mod)     -> Mod;
name(Fun) when is_function(Fun) -> {name, N} = erlang:fun_info(Fun, name), N.

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  true  = is_callback(test_callback),
  _     = test_behaviour:behaviour_info(foo),
  ok    = call(test_callback, f, []),
  Fun   = fun() -> ok end,
  Cb    = new([{f,0}, Fun], test_behaviour),
  true  = is_callback(Cb),
  Fun   = lookup(Cb, {f,0}),
  ok    = call(Cb, f, []),
  false = is_callback(fun(_, _) -> undefined end),
  false = is_callback({m,f,a}),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
