%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Promises.
%%% API inspired by Clojure:
%%%  promise   -> new
%%%  deliver   -> set
%%%  deref     -> get
%%%  realized? -> is_set
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
-module(meshup_promises).

%%%_* Exports ==========================================================
%% high level API
-export([ eval/2
        ]).

%% low level API
-export([ get/1
        , get/2
        , is_promise/1
        , is_set/1
        , new/1
        , set/2
        ]).

-export_type([ promise/0
             ]).

%% Internal exports
-export([ promise/1
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type msg()                                 :: is_set
                                             | get
                                             | {get, timeout()}
                                             | {set, _}.
-record(p, {romise                          :: fun((msg()) -> maybe(_, _))}).
-opaque promise()                           :: #p{}.

-define(empty, '__empty__').
-record(promise,
        { val=?empty                        :: _         %the value
        , pending=[]                        :: [pid()]   %blocked clients
        , timeout=throw('#promise.timeout') :: timeout() %TTL
        }).

%%%_ * high level API --------------------------------------------------
-spec eval(fun(), timeout()) -> promise().
%% @doc Return a promise for the result of Thunk, which gets Timeout ms
%% to run.
eval(Thunk, Timeout) ->
  P = new(Timeout),
  _ = proc_lib:spawn(?thunk({ok, _} = set(P, Thunk()))),
  P.

%%%_ * low level API ---------------------------------------------------
-spec new(timeout()) -> promise().
%% @doc Return a fresh promise.
%% The promise will GC itself after Timeout milliseconds without any of
%% the API functions being called on it.
new(Timeout) ->
  Pid = proc_lib:spawn(?thunk(promise(#promise{timeout=Timeout}))),
  #p{romise=fun(is_set = X)   -> call(Pid, X);
               (get = X)      -> call(Pid, X);
               ({get = X, T}) -> call(Pid, X, T);
               ({set, _} = X) -> call(Pid, X);
               (X)            -> throw({badmsg, X})
            end}.

-spec is_promise(_) -> boolean().
%% @doc Return true iff X is a promise.
is_promise(#p{})    -> true;
is_promise(_)       -> false.

-spec is_set(promise()) -> boolean().
%% @doc Return true iff Promise has a value, otherwise false.
is_set(#p{romise=P}) ->
  case P(is_set) of
    {ok, X}          -> X;
    {error, expired} -> true
  end.

-spec get(promise()) -> maybe(_, _).
%% @doc Get Promise's value. Blocks if Promise hasn't been set.
get(#p{romise=P})    -> P(get).

-spec get(promise(), timeout()) -> maybe(_, _).
%% @doc Get Promise's value. Blocks for T ms if Promise hasn't been set.
get(#p{romise=P}, T)            -> P({get, T}).

-spec set(promise(), _) -> maybe(_, _).
%% @doc Set Promise's value to Val. May only be called once.
set(#p{romise=P}, Val)  -> P({set, Val}).

%%%_ * Internals -------------------------------------------------------
promise(#promise{val=Val, pending=Pending, timeout=Timeout} = Promise) ->
  receive
    {Pid, is_set} ->
      ?given(Val =/= ?empty, Pending =:= []),
      tulib_processes:send(Pid, Val =/= ?empty),
      ?MODULE:promise(Promise);
    {Pid, get} ->
      case Val of
        ?empty ->
          ?MODULE:promise(Promise#promise{pending=[Pid|Pending]});
        _ ->
          ?hence(Pending =:= []),
          tulib_processes:send(Pid, {ok, Val}),
          ?MODULE:promise(Promise)
      end;
    {Pid, {set, V}} ->
      case Val of
        ?empty ->
          tulib_processes:send(Pid, {ok, V}),
          [tulib_processes:send(P, {ok, V}) || P <- Pending],
          ?MODULE:promise(Promise#promise{val=V, pending=[]});
        _ ->
          ?hence(Pending =:= []),
          tulib_processes:send(Pid, {error, {val, Val}}),
          ?MODULE:promise(Promise)
      end
  after
    Timeout -> ok %GC
  end.

call(Pid, Msg) ->
  call(Pid, Msg, infinity).

call(Pid, Msg, Timeout) ->
  tulib_processes:with_monitor(Pid, fun(Proc) ->
    tulib_processes:send(Proc, Msg),
    case tulib_processes:recv(Proc, Timeout) of
      {ok, Res}          -> Res;
      {error, {down, _}} -> {error, expired};
      {error, timeout}   -> {error, timeout}
    end
  end).

%%%_* Tests ============================================================
-ifdef(TEST).

set_get_is_test() ->
  Promise             = new(100),
  false               = is_set(Promise),
  {ok, foo}           = set(Promise, foo),
  {error, {val, foo}} = set(Promise, bar),
  true                = is_set(Promise),
  {ok, foo}           = ?MODULE:get(Promise),
  timer:sleep(101),
  {error, expired}    = ?MODULE:get(Promise),
  true                = is_set(Promise),
  true                = is_promise(Promise),
  ok.

blocking_test() ->
  Promise    = new(100),
  spawn(?thunk(timer:sleep(50), set(Promise, quux))),
  {ok, quux} = ?MODULE:get(Promise),
  ok.

gc_test() ->
  Promise          = new(50),
  {error, expired} = ?MODULE:get(Promise),
  ok.

misc_errors_test() ->
  Promise         = new(0),
  {badmsg, fetch} = (catch (Promise#p.romise)(fetch)),
  true            = is_promise(Promise),
  false           = is_promise(foo),
  false           = is_promise(fun(_) -> foo end),
  ok.

timeout_test() ->
  Promise          = new(100),
  {error, timeout} = ?MODULE:get(Promise, 10),
  {ok, foo}        = set(Promise, foo),
  {ok, foo}        = ?MODULE:get(Promise),
  ok.

eval_test() ->
  P        = eval(?thunk(42), 10),
  {ok, 42} = ?MODULE:get(P),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
