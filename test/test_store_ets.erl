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

-module(test_store_ets).
-export([new/0]).
-include_lib("tulib/include/prelude.hrl").

owner(Parent) ->
    Name = tulib_atoms:catenate([?MODULE, crypto:rand_uniform(0, 1 bsl 100)]),
    Tab  = ets:new(Name, [public]),
    ok   = tulib_processes:send(Parent, Tab),
    receive after infinity -> ok end.

new() ->
  Self      = self(),
  Pid       = spawn(?thunk(owner(Self))),
  {ok, Tab} = tulib_processes:recv(Pid),

  Del2 = fun(K, _) -> true = ets:delete(Tab, K), ok end,
  Get2 = fun(K, _) -> do_get(Tab, K) end,

  meshup_store:new(
    [ {del, 1}
    , fun(K) -> Del2(K, []) end

    , {del, 2}
    , Del2

    , {get, 1}
    , fun(K) -> Get2(K, []) end

    , {get, 2}
    , Get2

    , {merge, 3}
    , fun(_, _, V) -> {ok, V} end %LWW

    , {put, 2}
    , fun(K, V) -> true = ets:insert(Tab, {K, V}), ok end

    , {put, 3}
    , fun([fail], V, Opts) -> {error, {V, Opts}};
         (K, V, _)         -> true = ets:insert(Tab, {K, V}), ok
      end

    , {bind, 2}
    , fun(_K, V) -> {V, ''} end

    , {return, 2}
    , fun(_K, V) -> V end

    , {return, 3}
    , fun(_K, V, '') -> V end
    ]).

do_get(Tab, write_set)         -> lookup(Tab, write_set);
do_get(Tab, K) when is_list(K) -> lookup(Tab, K);
do_get(Tab, K) when is_atom(K) -> scan(Tab, K).

lookup(Tab, K) ->
  case ets:lookup(Tab, K) of
    [{_, V}] -> {ok, V};
    []       -> {error, notfound}
  end.

scan(Tab, Prefix) ->
  {ok, ets:select(
         Tab,
         [{ {'$1', '$2'} %K, V
            , [ {is_list, '$1'}
              , {'=:=', {hd, '$1'}, Prefix}
              ]
          ,['$2']        %V
          }])}.

%%% eof
