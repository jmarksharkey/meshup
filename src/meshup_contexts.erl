%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Input/output contexts.
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
-module(meshup_contexts).

%%%_* Exports ==========================================================
%% API
-export([ derive/3
        , fold/3
        , get/2
        , get/3
        , is_context/1
        , multiget/2
        , multiset/2
        , new/0
        , new/1
        , set/3
        , to_list/1
        , to_obj/1
        , transfer/2
        , transfer/3
        ]).

%% Pretty printer
-export([ pp/1
        ]).

-export_type([ context/0
             , literal/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/prelude.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-record(con, {text :: soabpox_obj:ect(name(), _)}).
-opaque context()  :: #con{}.
-type literal()    :: [name() | _].

-type name()       :: meshup_contracts:name().
-type pat()        :: meshup_contracts:pattern().
-type ctx()        :: context().

-define(tag(Obj),   #con{text=Obj}).
-define(untag(Ctx), Ctx#cont.text).

%%%_ * API -------------------------------------------------------------
-spec fold(fun(), A, ctx())        -> A.
fold(F, Acc, #con{text=Obj})       -> soapbox_obj:fold(F, Acc, Obj).

-spec get(ctx(), pat())            -> _ | no_return().
get(#con{text=Obj}, Pat)           -> soapbox_obj:get(Obj, match(Pat, Obj)).

-spec get(ctx(), pat(), A)         -> _ | A.
get(#con{text=Obj}, Pat, Def)      -> soapbox_obj:get(Obj,
                                                      match(Pat, Obj),
                                                      Def).

-spec is_context(_)                -> boolean().
is_context(#con{})                 -> true;
is_context(_)                      -> false.

-spec multiget(ctx(), [pat()])     -> [_] | no_return().
multiget(#con{text=Obj}, Pats)     -> soapbox_obj:multiget(
                                        Obj, matchl(Pats, Obj)).

-spec multiset(ctx(), [{pat(),_}]) -> ctx().
multiset(#con{text=Obj}, KVs)      -> ?tag(soapbox_obj:multiset(
                                             Obj, matcha(KVs, Obj))).

-spec new()                        -> ctx().
new()                              -> ?tag(soapbox_obj:new()).

-spec new([_] | soapbox_obj:ect()) -> ctx() | no_return().
new(Lst) when is_list(Lst)         -> ?tag(soapbox_obj:from_list(
                                             Lst,
                                             fun(K, _V) ->
                                               meshup_contracts:is_name(K)
                                             end));
new(Obj) when is_tuple(Obj)        -> ?tag(Obj).


-spec set(ctx(), pat(), _)         -> ctx().
set(#con{text=Obj}, Pat, V)        -> ?tag(soapbox_obj:set(
                                             Obj, match(Pat, Obj), V)).

-spec to_list(ctx())               -> [{name(), _}].
to_list(#con{text=Obj})            -> soapbox_obj:to_list(Obj).

-spec to_obj(ctx())                -> soapbox_obj:ect().
to_obj(#con{text=Obj})             -> Obj.


-spec transfer(ctx, [name() | {pat(), name()}]) -> ctx().
%% @equiv transfer(SrcCtx, new(), Ks)
transfer(SrcCtx, Ks) -> transfer(SrcCtx, new(), Ks).

-spec transfer(ctx(), ctx(), [name() | {pat(), name()}]) -> ctx().
%% @doc Transfer the values associated with Ks in SrcCtx to TgtCtx.
%% Ks contains either single keys, in which case the value will be
%% stored under the same key in the target context, or 2-tuples where
%% the first element is the key under which the value can be found in
%% the source context and the second element is the key under which the
%% value will be stored in the target context.
%% Keys which are not present in the source context are ignored.
transfer(SrcCtx, TgtCtx, Ks) ->
  F = fun({K1, K2}, Acc) ->
          ?hence(meshup_contracts:is_name(K2)),
          try   set(Acc, K2, get(SrcCtx, K1))
          catch error:{not_found, K1} -> Acc
          end;
         (K, Acc) ->
          ?hence(meshup_contracts:is_name(K)),
          try   set(Acc, K, get(SrcCtx, K))
          catch error:{not_found, K} -> Acc
          end
      end,
  lists:foldl(F, TgtCtx, Ks).


-spec derive(ctx(), pat(), fun((ctx()) -> A)) -> A.
%% @doc Return the value associated with K in Ctx or the result of
%% applying F to Ctx if no value is associated with K.
derive(Ctx, K, F) ->
  case ?lift(get(Ctx, K)) of
    {ok, V}    -> V;
    {error, _} -> F(Ctx)
  end.

%%%_ * Helpers ---------------------------------------------------------
match(Pat, Obj)    -> {ok, [Name]} = meshup_matcher:match([Pat], Obj),
                      Name.
matchl(Pats, Obj)  -> {ok, Names}  = meshup_matcher:match(Pats, Obj),
                      Names.
matcha(Alist, Obj) -> {Pats, Vals} = lists:unzip(Alist),
                      {ok, Names}  = meshup_matcher:match(Pats, Obj),
                      lists:zip(Names, Vals).

%%%_ * Pretty Printer ==================================================
-spec pp(ctx()) -> meshup_pp:printable().
pp(Ctx) ->
  meshup_pp:cat(
    [meshup_pp:header("Context")] ++
    [meshup_pp:fmtln("~p => ~p", [K, V]) || {K, V} <- to_list(Ctx)]).

%%%_* Tests ============================================================
-ifdef(TEST).

get_set_to_test() ->
  K        = [srvc, tab, key],
  K2       = [srvc, tab, key2],
  V        = 42,

  Ctx1     = set(new(), K, V),
  V        = get(Ctx1, K),

  Ctx2     = new([K, V]),
  V        = get(Ctx2, K),

  Ctx3     = new([K, V]),
  V        = get(Ctx3, K),
  V        = get(Ctx3, K2, V),

  Lst1     = to_list(Ctx1),
  Lst2     = soapbox_obj:to_list(to_obj(Ctx2)),
  [{K, V}] = Lst1,
  Lst1     = Lst2,
  true     = is_context(Ctx1),
  false    = is_context(Lst1),

  Ctx1     = new(to_obj(Ctx1)),

  ok.

multi_test() ->
  K1       = [s1, t1, k1],
  K2       = [s2, t2, k2],
  K3       = [s3, t3, k3],
  V1       = foo,
  V2       = bar,
  Ctx0     = new(),
  Ctx1     = multiset(Ctx0, [{K1, V1}, {K2, V2}]),
  [V1, V2] = multiget(Ctx1, [K1, K2]),
  ?assertError({not_found, K3}, multiget(Ctx1, [K1, K3])),
  ok.

match_test() ->
  Ctx1     = new([ [foo, bar],  42
                 , [baz, quux], bar
                 ]),
  42       = get(Ctx1, [foo, bar]),
  42       = get(Ctx1, [foo, {x}]),
  42       = get(Ctx1, [foo, {{[baz,quux]}}]),

  Ctx2     = new([ [foo, bar],  42
                 , [baz, quux], bar
                 ]),
  666      = get(Ctx2, [foo, baz],           666),
  666      = get(Ctx2, [bar, {x}],           666),
  42       = get(Ctx2, [foo, {{[baz,{x}]}}], 666),

  Ctx3     = new([ [foo, bar],    42
                 , [baz, quux],   bar
                 , [snarf, quux], 43
                 ]),
  [42, 43] = multiget(Ctx3, [ [foo, {{[baz,{x}]}}]
                            , [snarf, {x}] %vars bind vars
                            ]),

  ok.

transfer_test() ->
  K1   = [s1, t1, k1],
  K2   = [s2, t2, k2],
  K3   = [s3, t3, k3],
  K4   = [s4, t4, k4],
  K5   = [s5, t5, k5],
  V1   = foo,
  V2   = bar,
  V3   = baz,

  Ctx0 = new([K1, V1, K2, V2]),
  Ctx1 = new([K3, V3]),

  %% Test transfer from Ctx0 to Ctx1.
  ?assertEqual([{K1, V1}, {K3, V3}, {K4, V2}],
               lists:sort(to_list(transfer(Ctx0, Ctx1, [K1, {K2, K4}])))),
  %% Test transfer from Ctx0 to new context().
  ?assertEqual([{K1, V1}, {K4, V2}],
               lists:sort(to_list(transfer(Ctx0, [K1, {K2, K4}])))),
  %% Test that non-existing keys are ignored
  ?assertEqual([{K3, V3}],
               to_list(transfer(Ctx0, Ctx1, [K4, {K4, K5}]))),
  ok.

fold_test() ->
  [{[s,b,k],42}] = fold(fun(Name, Value, Acc) ->
                          [{Name,Value}|Acc]
                        end, [], new([[s,b,k],42])),
  ok.

derive_test() ->
  F  = fun(X) -> X end,
  42 = F(42), %cover
  42 = derive(new([[s,b,k], 42]),
              [s,b,k],
              F),
  42 = derive(new([[s,b,k1], 41, [s,b,k2], 1]),
              [s,b,k],
              fun(Ctx) -> get(Ctx, [s,b,k1]) + get(Ctx, [s,b,k2]) end),
  ok.

pp_test() ->
  io:format(user, "~s~n", [pp(new([ [foo,bar],   42
                                  , [baz, quux], 43
                                  ]))]),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
