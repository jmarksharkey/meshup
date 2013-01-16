%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Types and library functions for MeshUp service-contracts.
%%%
%%% Each service API is associated with an input and an output contract via the
%%% meshup_service:describe/2 callback.
%%% Contracts serve the dual purposes of describing the shape of an
%%% input/output context and associating metadata with specific input/output
%%% items.
%%%
%%% Contracts are collections of names (similar to primary keys in a database)
%%% optionally tied to a set of annotations.
%%% Each name lives in a namespace, ensuring global uniqueness.
%%% Since contracts are compile-time artifacts whereas names are frequently
%%% calculated at run-time, a pattern-language denotes variable components
%%% of names.
%%%
%%% Contexts may be viewed as instantiations of contracts:
%%% name-patterns are replaced by actual names, which point to the current
%%% value of the data-item they identify.
%%%
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
-module(meshup_contracts).

%%%_* Exports ==========================================================
%% Names
-export([ is_const/1
        , is_name/1
        , is_subst/1
        , is_var/1
        , subst_fun/1
        , subst_target/1
        ]).

%% Namespacing
-export([ in_namespace/2
        , namespace/1
        ]).

%% Contract ADT
-export([ call/1
        , clauses/1
        , type/1
        ]).

%% Contract API
-export([ fold/4
        , parse/2
        ]).

%% Pretty Printing
-export([ pp/1
        ]).

-export_type([ contract/0
             , declaration/0
             , name/0
             , namespace/0
             , pattern/0
             , type/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Macros ===========================================================
-define(listof(Xs, Pred), (tulib_predicates:is_nonempty_list_of(Xs, Pred))).

%%%_* Code =============================================================
%%%_ * Names -----------------------------------------------------------
%% The pattern matcher operates on arbitrarily nested lists.
-type pattern()                   :: [subpat()].
-type subpat()                    :: [subpat()] %composite
                                   | const()    %\
                                   | var()      % } simple
                                   | subst().   %/
-type const()                     :: atom()
                                   | integer()
                                   | tuple().
-type var()                       :: {atom()}.
-type subst()                     :: {{prim_pat()}} %value substitution
                                   | {{prim_pat(), subst_fun()}}.
-type prim_pat()                  :: [prim_subpat()].
-type prim_subpat()               :: [prim_subpat()]
                                   | const() %\ no recursive
                                   | var().  %/ substitutions
-type subst_fun()                 :: fun((_) -> _).

%% Contexts map constant names to data items.
-type name()                      :: [subname()].
-type subname()                   :: [subname()]
                                   | const().


is_pattern(X)                     -> ?listof(X, fun is_subpat/1).
is_subpat(X) when is_list(X)      -> ?listof(X, fun is_subpat/1);
is_subpat(X)                      -> is_const(X) orelse
                                     is_var(X)   orelse
                                     is_subst(X).

is_const(X)                       -> is_atom(X)    orelse
                                     is_integer(X) orelse
                                     (is_tuple(X) andalso size(X) > 1).

is_var({V})                       -> is_atom(V);
is_var(_)                         -> false.

is_subst({{T}})                   -> is_prim_pat(T);
is_subst({{F, T}})                -> is_function(F, 1) andalso is_prim_pat(T);
is_subst(_)                       -> false.

is_prim_pat(X)                    -> ?listof(X, fun is_prim_subpat/1).
is_prim_subpat(X) when is_list(X) -> ?listof(X, fun is_prim_subpat/1);
is_prim_subpat(X)                 -> is_const(X) orelse
                                     is_var(X).

is_name(X)                        -> ?listof(X, fun is_subname/1).
is_subname(X) when is_list(X)     -> ?listof(X, fun is_subname/1);
is_subname(X)                     -> is_const(X).

%%%_ * Utilities -------------------------------------------------------
%% The first element of a name indicates the namespace.
%% `shared' and `meshup' data items belong to all namespaces.
%% Every data item belongs to the `any' namespace.

-type namespace()                       :: subname().

-spec in_namespace(namespace(), name()) -> boolean().
in_namespace(NS,  [NS|_])               -> true;
in_namespace(_,   [shared|_])           -> true;
in_namespace(_,   [meshup|_])           -> true;
in_namespace(any, [_|_])                -> true;
in_namespace(_,   _)                    -> false.

-spec namespace(name())                 -> namespace().
namespace([NS|_])                       -> NS.

%% The pattern matcher replaces substitutions by the result of applying
%% the substitution function to the value associated with the
%% substitution target in the evaluation context.
subst_target({{T}})     -> T;
subst_target({{_F, T}}) -> T.

subst_fun({{_T}})       -> fun(X) -> X end;
subst_fun({{F, _T}})    -> F.

-spec subst_targets([pattern()]) -> [prim_pat()].
subst_targets(Ns) ->
  lists:foldl(fun(N, Acc) -> Acc ++ subst_targets1(N) end, [], Ns).

subst_targets1(N) ->
  lists:foldl(fun(C, Acc) -> Acc ++ subst_targets2(C) end, [], N).

subst_targets2(C) when is_list(C) -> subst_targets1(C);
subst_targets2({{T}})             -> [T];
subst_targets2({{_F, T}})         -> [T];
subst_targets2(_)                 -> [].

%%%_ * Contracts -------------------------------------------------------
%% Contract declarations consist of a list of names, optionally
%% associated with a list of annotations.
%% Contract declarations are parsed and converted into values of an ADT.
-type declaration()          :: [clause_decl()].
-type clause_decl()          :: pattern()
                              | {pattern(), annotations()}.
-type annotation()           :: {optional, boolean()}
                              | {store, meshup_callbacks:callback()}.
-type annotations()          :: [annotation()].

-type type()                 :: input | output.
-type clauses()              :: [{pattern(), annotations()}].

-record(c,
        { call               :: {atom(), atom()}
        , type               :: type()
        , clauses            :: clauses()
        }).

-opaque contract()           :: #c{}.

-spec call(contract())       -> {atom(), atom()}.
call(#c{call=C})             -> C.

-spec type(contract())       -> type().
type(#c{type=T})             -> T.

-spec clauses(contract())    -> clauses().
clauses(#c{clauses=Cs})      -> Cs.


is_annotation({store,    X}) -> meshup_callbacks:is_callback(X);
is_annotation({optional, X}) -> is_boolean(X);
is_annotation(_)             -> false.

%%%_ * Parser ----------------------------------------------------------
-spec parse(meshup_service:sm(), type()) -> maybe(contract(), _).
parse({Service, Method}, Type) ->
  tulib_maybe:lift(?thunk(
    Name = meshup_service:name(Service),
    #c{ call    = {Name, Method}
      , type    = Type
      , clauses = parse(meshup_service:describe(Service, Method, Type),
                        Name,
                        Type)
      })).

parse(Decl, Name, Type) ->
  ?hence(name =/= shared andalso name =/= any),
  Clauses = do_parse(Decl),
  Pats    = soapbox_obj:keys(Clauses),
  Store   = fun(Pat) ->
              tulib_lists:assoc(store, soapbox_obj:get(Clauses, Pat))
            end,

  %% Services may only read from their own namespace.
  [assert(fun(Pat) ->
            case Store(Pat) of
              {ok, _}           -> in_namespace(Name, Pat);
              {error, notfound} -> true
            end
          end,
          Pats,
          bad_reads) || Type =:= input],

  %% Services may only produce output in their own namespace.
  [assert(fun(Pat) -> in_namespace(Name, Pat) end,
          Pats,
          bad_namespacing) || Type =:= output],

  %% Shared items may not live in a store.
  assert(fun(Pat) ->
           case Store(Pat) of
             {ok, _}           -> namespace(Pat) =/= shared;
             {error, notfound} -> true
           end
         end,
         Pats,
         bad_sharing),

  %% Substitutions must point to existing names.
  %% FIXME: this means that _in contracts_, substitutions can't bind
  %% vars.
  assert(fun(ST) -> lists:member(ST, Pats) end,
         subst_targets(Pats),
         bad_subst_targets),

  soapbox_obj:to_list(Clauses).


%% The SoapBox object constructor does most of the work...
do_parse(Decl) ->
  soapbox_obj:from_proplist(
    [case Clause of
       {Pat, As} -> {Pat, canonicalize(As)};
       Pat       -> {Pat, canonicalize([])}
     end || Clause <- Decl],
    fun(K, V) ->
      is_pattern(K) andalso lists:all(fun is_annotation/1, V)
    end).

canonicalize(As) ->
  case tulib_lists:assoc(optional, As) of
    {ok, _}           -> As;
    {error, notfound} -> [{optional, false}|As]
  end.


assert(Pred, Xs, Rsn) ->
  case [X || X <- Xs, not Pred(X)] of
    []  -> ok;
    Bad -> throw({Rsn, Bad})
  end.

%%%_ * Folding ---------------------------------------------------------
-spec fold(fun(({name(), annotations()}, A) -> A),
           A,
           contract(),
           meshup_matcher:obj()) -> maybe(A, _).
%% @doc Fold Fun into Acc over Contract evaluated against Obj.
fold(Fun, Acc, Contract, Obj) ->
  Call       = call(Contract),
  {Pats, As} = lists:unzip(clauses(Contract)),
  case meshup_matcher:match(Pats, Obj) of
    {ok, Names} ->
      do_fold(Fun,
              Acc,
              lists:zip(Names, As),
              Call);
    {error, Rsn} -> {error, {Call, Rsn}}
  end.

do_fold(Fun, Acc0, [{Name, As} = First|Rest], Call) ->
  case is_name(Name) of
    true ->
      case Fun(First, Acc0) of
        {ok, Acc}    -> do_fold(Fun, Acc, Rest, Call);
        {error, Rsn} -> {error, {Call, Rsn}}
      end;
    false ->
      case tulib_lists:assoc(optional, As) of
        {ok, true}  -> do_fold(Fun, Acc0, Rest, Call);
        {ok, false} -> {error, {Call, {unmatched_pattern, Name}}}
      end
  end;
do_fold(Fun, Acc0, [], Call) ->
  case Fun([], Acc0) of
    {ok, _} = Ok -> Ok;
    {error, Rsn} -> {error, {Call, Rsn}}
  end.

%%%_* Pretty Printer ===================================================
-spec pp(contract()) -> meshup_pp:printable().
pp(#c{type=T, clauses=Cs}) ->
  meshup_pp:cat(
    [meshup_pp:header(tulib_lists:to_list(T))] ++
      [meshup_pp:fmtln("~s (~s)", [pp_name(N), pp_annotations(As, T)])
       || {N, As} <- Cs]).

pp_name([NS|N]) -> meshup_pp:fmt("~p.~p", [NS, N]).

pp_annotations(As, T) ->
  {ok, Optional} = tulib_lists:assoc(optional, As),
  Store          = tulib_lists:assoc(store, As, ram),
  meshup_pp:fmt("~sly ~s ~p", [ case Optional of
                                  true  -> "optional";
                                  false -> "mandatori"
                                end
                              , case T of
                                  input  -> "from";
                                  output -> "to"
                                end
                              , Store
                              ]).

%%%_* Tests ============================================================
-ifdef(TEST).

names_test() ->
  ?assert(is_pattern([foo,[{x},bar,{{[quux,{y}]}}],baz])),
  ?assert((not is_pattern([foo,{{x}}])) ),
  ?assert((not is_subst({{[foo,{{bar}}]}})) ),
  ?assert(is_name([foo,bar,[baz,quux]])),
  ?assert((not is_name([foo,bar,[baz,{x}]]))),
  ?assert((is_name([foo,bar,{1,2,3}]))),
  ?assert((not is_var(x))),
  ?assert((not is_subst(x))),
  ?assert((not is_subst({snarf}))),
  ?assert((not is_annotation(foo))),
  ok.

utilities_test() ->
  true  = in_namespace(s, [s,[b,k]]),
  true  = in_namespace(any, [s,[b,k]]),
  false = in_namespace(n, [s,[b,k]]),
  true  = in_namespace(s, [meshup, k]),
  snarf = subst_target({{snarf}}),
  snarf = subst_target({{f, snarf}}),
  true  = is_function(subst_fun({{snarf}}), 1),
  f     = subst_fun({{f, snarf}}),
  ok.

%%
%% Contracts
%%
basic_test() ->
  Srvc =
    meshup_service:make(
      fun(_, _)        -> throw(undefined) end,
      fun(api, input)  -> [ [s0, [b0, k0]]
                          , [s1, [b0, k0]]
                          ];
       (api, output) -> [ [s0, [b0, k0]]
                        , [s0, [b0, k1]]
                        ]
      end,
      fun() -> s0 end),

  catch meshup_service:call(Srvc,foo,bar), %cover

  {ok, C} = parse({Srvc, api}, input),
  {ok, _} = parse({Srvc, api}, output),
  input   = type(C),
  Lst     = clauses(C),
  true    = lists:member({[s0,[b0,k0]],[{optional,false}]}, Lst),
  ok.

annotations_test() ->
  In1        = [ {[s0, [b0, k0]], [ {optional, true}
                                  , {store, mystore}
                                  ]}
               ],
  Cs         = parse(In1,  s0, input),
  {ok, As}   = tulib_lists:assoc([s0, [b0, k0]], Cs),
  {ok, true} = tulib_lists:assoc(optional, As),

  In2        = [ {[s0, [b0, k0]], [{optional, snarf}]}
               ],
  {error, _} = ?lift(parse(In2, s0, input)),

  ok.

syntax_test() ->
  {error, _} = ?lift(parse([{s0,n0}], s0, input)),
  ok.

subst_target_test() ->
  F          = fun(X) -> X end,
  42         = F(42), %cover
  In1        = [ [s0,[b0,{x}]]
               , [s1,[b1,{{F, [s0,[b0,{x}]]}}]]
               ],
  {ok, _}    = ?lift(parse(In1, s0, input)),

  In2        = [ [s0,[b0,{x}]]
               , [s1,[b1,{{[s0,[b0,{y}]]}}]]
               ],
  {error, _} = ?lift(parse(In2, s0, input)),

  ok.

namespacing_test() ->
  {error, _} = ?lift(parse(s0, [[s1, [b0,k0]]], output)),
  ok.

shared_ok_test() ->
  In      = [ [foo,bar]
            , [shared,baz]
            , [service,quux]
            ],
  Out     = [ [service,snarf]
            , [shared,baz]
            , [shared,blarg]
            ],
  {ok, _} = ?lift(parse(In,  service, input)),
  {ok, _} = ?lift(parse(Out, service, output)),
  ok.

shared_error_test() ->
  Out        = [ [service,snarf]
               , [shared,baz]
               , {[shared,blarg], [{optional,true}, {store,some_store}]}
               ],
  {error, _} = ?lift(parse(Out, service, output)),
  {error, _} = ?lift(parse(Out, service, input)),
  ok.

pp_test() ->
  Srvc     =
    meshup_service:make(
      fun(_, _)        -> throw(undefined) end,
      fun(api, input)  -> [ [s1,[b1,k1]]
                          ];
         (api, output) -> [ {[s0,[b0,k0]],
                             [{optional,true},{store,mystore}]}
                          ]
      end,
      fun() -> s0 end),

  %% Cover
  catch meshup_service:call(Srvc, foo, bar),

  {ok, IC} = parse({Srvc, api}, input),
  {ok, OC} = parse({Srvc, api}, output),
  io:format(user, "~n~s~n", [pp(IC)]),
  io:format(user, "~s~n",   [pp(OC)]),
  ok.


fold_test() ->
  Srvc1     = service1(),
  {ok, IC1} = parse({Srvc1, api}, input),
  {ok, OC1} = parse({Srvc1, api}, output),
  Srvc2     = service2(),
  {ok, IC2} = parse({Srvc2, api}, input),
  {ok, _}   = parse({Srvc2, api}, output),
  Obj1      = obj1(),
  Obj2      = obj2(),
  Fun       = fun({Name, _As}, Acc) -> {ok, [soapbox_obj:get(Obj1, Name)|Acc]};
                 ([],          Acc) -> {ok, Acc}
              end,

  {ok, [42]} =
    fold(Fun, [], IC1, Obj1),
  {error, {_, foo}} =
    fold(fun(_, _) -> {error, foo} end, [], IC1, Obj1),
  {error, {_, foo}} =
    fold(fun([], _) -> {error, foo};
            (_, X)  -> {ok, X}
         end, [], IC1, Obj1),
  {error, {_, {unmatched_pattern, _}}} =
    fold(Fun, [], OC1, Obj1),
  {error, {_, {lifted_exn, {multi_match, _, _, _}, _}}} =
    fold(Fun, [], IC2, Obj2),

  %% Cover
  catch meshup_service:call(Srvc1, foo, bar),
  catch meshup_service:call(Srvc2, foo, bar),

  ok.


service1() ->
  meshup_service:make(
    fun(_, _)        -> throw(nyi) end,
    fun(api, input)  -> [ [s, b0, k0]
                        , {[s, b1, {x}], [{optional, true}]}
                        ];
       (api, output) -> [ [s, b2, {x}] ]
    end,
    fun()            -> s end).

service2() ->
  meshup_service:make(
    fun(_, _)        -> throw(nyi) end,
    fun(api, input)  -> [ [s, b0, {x}] ];
       (api, output) -> [ ]
    end,
    fun()            -> s end).

obj1() -> soapbox_obj:from_list([ [s, b0, k0], 42 ]).

obj2() -> soapbox_obj:from_list([ [s, b0, k0], 42
                                , [s, b0, k1], 43
                                ]).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
