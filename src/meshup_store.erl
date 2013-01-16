%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc MeshUp data store behaviour.
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
-module(meshup_store).

%%%_* Exports ==========================================================
-export([ behaviour_info/1
        , make/7
        , make/10
        , new/1
        ]).

-export([ bind/3
        , del/2
        , del/3
        , get/2
        , get/3
        , merge/4
        , put/3
        , put/4
        , return/3
        , return/4
        ]).

-export([ get_/2
        , get_/3
        , patch_/3
        , patch_/4
        , put_/3
        , put_/4
        ]).

-export_type([ key/0
             , val/0
             , obj/0
             , opts/0
             , meta/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Code =============================================================
%%%_ * Behaviour -------------------------------------------------------
-type key()  :: _.
-type val()  :: _.
-type obj()  :: _.
-type opts() :: [_].
-type meta() :: _.

%% -callback bind(key(), obj())           -> {val(), meta()}.
%% -callback del(key())                   -> maybe(key(), _).
%% -callback del(key(), opts())           -> maybe(key(), _).
%% -callback get(key())                   -> maybe(obj(), _).
%% -callback get(key(), opts())           -> maybe(obj(), _).
%% -callback merge(key(), val(), val())   -> maybe(val(), _).
%% -callback put(key(), obj())            -> maybe(obj(), _).
%% -callback put(key(), obj(), opts())    -> maybe(obj(), _).
%% -callback return(key(), val())         -> obj().
%% -callback return(key(), val(), meta()) -> obj().

behaviour_info(callbacks) ->
  [ {bind,   2}
  , {del,    1}
  , {del,    2}
  , {get,    1}
  , {get,    2}
  , {merge,  3}
  , {put,    2}
  , {put,    3}
  , {return, 2}
  , {return, 3}
  ];
behaviour_info(_) -> undefined.

new(Mtab) -> meshup_callbacks:new(Mtab, ?MODULE).

make(Bind, Del, Get, Merge, Put, Return2, Return3) ->
  make(Bind,
       Del,
       fun(K, _) -> Del(K) end,
       Get,
       fun(K, _) -> Get(K) end,
       Merge,
       Put,
       fun(K, V, _) -> Put(K, V) end,
       Return2,
       Return3).
make(Bind, Del1, Del2, Get1, Get2, Merge, Put2, Put3, Return2, Return3) ->
  new(
    [ {bind,   2}, Bind
    , {del,    1}, Del1
    , {del,    2}, Del2
    , {get,    1}, Get1
    , {get,    2}, Get2
    , {merge,  3}, Merge
    , {put,    2}, Put2
    , {put,    3}, Put3
    , {return, 2}, Return2
    , {return, 3}, Return3
    ]).

bind(S, K, Obj)     -> meshup_callbacks:call(S, bind,    [K, Obj]).
del(S, K)           -> meshup_callbacks:call(S, del,     [K]).
del(S, K, O)        -> meshup_callbacks:call(S, del,     [K, O]).
get(S, K)           -> meshup_callbacks:call(S, get,     [K]).
get(S, K, O)        -> meshup_callbacks:call(S, get,     [K, O]).
merge(S, K, V1, V2) -> meshup_callbacks:call(S, merge,   [K, V1, V2]).
put(S, K, V)        -> meshup_callbacks:call(S, put,     [K, V]).
put(S, K, V, O)     -> meshup_callbacks:call(S, put,     [K, V, O]).
return(S, K, V)     -> meshup_callbacks:call(S, return,  [K, V]).
return(S, K, V, M)  -> meshup_callbacks:call(S, return,  [K, V, M]).

%%%_ * Utilities -------------------------------------------------------
%% Obj         = return(Key, Val)
%% {Val, Meta} = bind(Key, Obj)
%% Obj         = return(Key, Val, Meta)

patch_(Store, Key, Fun) ->
  patch_(Store, Key, Fun, []).
patch_(Store, Key, Fun, Opts) ->
  tulib_maybe:lift_with(
    meshup_store:get(Store, Key, Opts),
    fun(Obj) ->
      {Val0, Meta} = meshup_store:bind(Store, Key, Obj),
      Val          = Fun(Val0),
      ok           = meshup_store:put(Store,
                                      Key,
                                      meshup_store:return(Store, Key, Val, Meta)),
      Val
    end).


get_(Store, Key) ->
  get_(Store, Key, []).
get_(Store, Key, Opts) ->
  tulib_maybe:lift_with(
    meshup_store:get(Store, Key, Opts),
    fun(Obj) ->
      {Val, _} = meshup_store:bind(Store, Key, Obj),
      Val
    end).


put_(Store, Key, Val) ->
  meshup_store:put(Store, Key, meshup_store:return(Store, Key, Val)).

put_(Store, Key, Val, Meta) ->
  meshup_store:put(Store, Key, meshup_store:return(Store, Key, Val, Meta)).

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  erase(),
  Store             = mystore(),
  {error, notfound} = ?MODULE:get(Store, [foo,bar]),
  ok                = ?MODULE:put(Store, [foo,bar], 42),
  ok                = ?MODULE:put(Store, [foo,bar], 42, []),
  {ok, 42}          = ?MODULE:get(Store, [foo,bar], []),
  ok                = ?MODULE:del(Store, [foo,bar]),
  ok                = ?MODULE:del(Store, [foo,bar], []),

  {ok, bar}         = merge(Store, [foo,bar], foo, bar),
  {X, Meta}         = bind(Store, [foo,bar], now()),
  X                 = return(Store, [foo,bar], X, Meta),

  ok                = ?MODULE:put_(Store, [foo,bar], 0),
  ok                = ?MODULE:put_(Store, [foo,bar], 0, []),
  {ok, 1}           = patch_(Store, [foo,bar], fun(X) -> X + 1 end),
  {ok, 1}           = get_(Store, [foo,bar]),

  erase(),
  ok.

mystore() ->
  make(fun(_K, V) -> {V, []} end,
       fun(K) -> erase(K), ok end,
       fun(K) -> case get(K) of
                   undefined -> {error, notfound};
                   V         -> {ok, V}
                 end
       end,
       fun(_K, _V1, V2) -> {ok, V2} end,
       fun(K, V) -> put(K, V), ok end,
       fun(_K, V) -> V end,
       fun(_K, V, []) -> V end).

stupid_test() -> _ = behaviour_info(foo).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
