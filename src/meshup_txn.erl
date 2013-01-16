%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Generate a flow from an annotated function.
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
-module(meshup_txn).

%%%_* Exports ==========================================================
-export([ txn/3
        , txn/4
        ]).

%%%_* Includes =========================================================
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
-type txn_fun()  :: fun((meshup_contexts:context()) ->
                           meshup_contexts:context()).
-type txn_decl() :: meshup_contracts:contract_decl().
-type txn_ret()  :: maybe(_, _).

%% @doc Run a transaction (a generated flow analogous to Fun).
%% Reads/Writes describe the contexts which F consumes/produces.
%% These are similar to service contracts, but store annotations are
%% implicit, and there aren't any namespace restrictions.
-spec txn(txn_fun(), txn_decl(), txn_decl()) -> txn_ret().
txn(Txn, Reads, Writes) ->
  txn(Txn, Reads, Writes, async).
txn(Txn, Reads, Writes, Mode) ->
  ReadSteps  = read_steps(Reads),
  WriteSteps = write_steps(Writes),
  TxnStep    = [{txn_service(Txn), txn}],
  Endpoint   = meshup_endpoint:make(
                 fun() ->
                   ReadSteps ++
                   TxnStep   ++
                   WriteSteps
                 end),
  Input      = meshup_contexts:new([ [shared, ctx], meshup_contexts:new() ]),
  case
    ?lift(meshup:start([ {endpoint, Endpoint}
                       , {input,    Input}
                       , {mode,     Mode}
                       ]))
  of
    {ok, _}          -> ok;
    {error, _} = Err -> Err
  end.

%% We set up a flow of services which read and write data items from
%% specific namespaces around a service which performs some computation
%% on that data.
read_steps(Reads) ->
  [{read_service(NS, In), read} || {NS, In} <- partition(Reads)].

write_steps(Writes) ->
  [{write_service(NS, Out), write} || {NS, Out} <- partition(Writes)].

%% @doc Take a transaction contract and turn it into several service
%% contracts which respect namespacing. Note that store annotations are
%% mandatory in transaction contracts.
partition(Reads) ->
  partition(Reads, dict:new()).
partition([{[NS|_], [{store, _}]} = First|Rest], Acc) ->
  partition(Rest, dict:update(NS, fun(In) -> [First|In] end, [First], Acc));
partition([], Acc) ->
  dict:to_list(Acc).

%% Read services build up an in-context for the transaction service.
read_service(NS, In) ->
  meshup_service:make(
    fun(read, Ctx)    -> meshup:ok(fold(Ctx)) end,
    fun(read, input)  -> [[shared, ctx]|In];
       (read, output) -> [[shared, ctx]]
    end,
    fun()             -> NS end
   ).

%% Each write service processes a subset of the out-context produced by
%% the transaction service.
write_service(NS, Out) ->
  meshup_service:make(
    fun(write, Ctx)    -> meshup:ok(unfold(Ctx, NS)) end,
    fun(write, input)  -> [[shared, ctx]];
       (write, output) -> Out
    end,
    fun()              -> NS end
   ).

%% @doc Merge an intermediate in-context into the shared context.
fold(Ctx) ->
  meshup_contexts:new([[shared, ctx],
    meshup_contexts:fold(
      fun([shared, ctx], _, SharedCtx) -> SharedCtx; %skip self
         (K,             V, SharedCtx) -> meshup_contexts:set(SharedCtx, K, V)
      end, meshup_contexts:get(Ctx, [shared, ctx]), Ctx)]).

%% @doc Extract the data for NS from the shared context.
unfold(Ctx, NS1) ->
  meshup_contexts:fold(
    fun([NS2|_] = K, V, Ctx) when NS1 =:= NS2 -> meshup_contexts:set(Ctx, K,V);
       (_,           _, Ctx)                  -> Ctx %wrong namespace
    end, meshup_contexts:new(), meshup_contexts:get(Ctx, [shared, ctx])).


%% Do the business.
txn_service(Fun) ->
  meshup_service:make(
    fun(txn, Ctx) ->
      InCtx  = meshup_contexts:get(Ctx, [shared, ctx]),
      OutCtx =
          case Fun(InCtx) of
            Lit when is_list(Lit) -> meshup_contexts:new(Lit);
            X                     -> X
          end,
      meshup:ok(meshup_contexts:new([[shared, ctx], OutCtx]))
    end,
    fun(txn, input)  -> [[shared, ctx]];
       (txn, output) -> [[shared, ctx]]
    end,
    fun()            -> undefined end
   ).

%%%_* Tests ============================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

txn_test() ->
  init_meshup(),
  DB   = test_store_ets:new(),
  ok   = init_db(DB),
  Txn  = txn(),
  Decl = decl(DB),
  ok   = txn(Txn, Decl, Decl),
  ok.

steps_test() ->
  DB = test_store_ets:new(),
  _  = read_steps(decl(DB)),
  _  = write_steps(decl(DB)),
  ok.

services_test() ->
  _ = read_service(ns, []),
  _ = write_service(ns, []),
  _ = txn_service(txn()),
  ok.

partition_test() ->
  DB = test_store_ets:new(),
  [ {ns1, [{[ns1, k1], [{store, DB}]}]}
  , {ns2, [{[ns2, k2], [{store, DB}]}]}
  ] = partition(decl(DB)),
  ok.


init_meshup() ->
  ok = application:set_env(meshup, timeout, 100),
  ok = application:set_env(meshup, store,   test_store_ets:new()),
  ok = application:set_env(meshup, logger,  test_logger),
  ok.

init_db(DB) ->
  ok = meshup_store:put(DB, [ns1, k1], 42),
  ok = meshup_store:put(DB, [ns2, k2], 666).

txn() ->
  fun(Ctx) ->
      V1 = meshup_contexts:get(Ctx, [ns1, k1]),
      V2 = meshup_contexts:get(Ctx, [ns2, k2]),
      meshup_contexts:new(
        [ [ns1, k1], V1+1
        , [ns2, k2], V2+1
        ])
  end.

decl(DB) ->
  [ {[ns1, k1], [{store, DB}]}
  , {[ns2, k2], [{store, DB}]}
  ].

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
