%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc State represetation used while computing the result of a flow.
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
-module(meshup_state).

%%%_* Exports ==========================================================
%% States
-export([ await/1
        , get/2
        , init/2
        , init/3
        , merge/2
        , new/0
        , new/1
        , set/3
        , to_context/1
        , to_obj/1
        , write/3
        ]).

-export([ compress/1
        , uncompress/1
        ]).

%% Printing
-export([ pp/1
        ]).

-export_type([ state/0
             ]).

%%%_* Includes =========================================================
-include("shared.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("meshup/include/test.hrl").
-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/logging.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type name()      :: meshup_contracts:name().
-type store()     :: meshup_callbacks:callback().
-type context()   :: meshup_contexts:context().

%% A single version of the value of a data item.
-record(item,
        { term    :: _
        , vsn=0   :: non_neg_integer()
        , source  :: source()
        }).

%% Each data item has a name (either the primary DB key, or an arbitrary
%% handle used to identify ephemeral data items during the evaluation of
%% a flow), a value-history, and, if the data item lives in some
%% data store, a handle to that store plus store-specific
%% meta-information.
-record(data,
        { name     :: name()
        , vals=[]  :: [#item{}]
        , store='' :: store()
        , meta     :: _
        }).

%% Data is either provided as input to a flow, read from storage, or
%% computed by one of the steps in a flow.
-type source()    :: store()             %imported
                   | meshup_service:sa() %computed
                   | input.              %external

%% A state is a collection of data items. It may be viewed as the
%% database against which a flow is evaluated.
-opaque state()   :: soapbox_obj:ect(name(), #data{}).

%%%_ * API -------------------------------------------------------------
%%%_  * Constructor ----------------------------------------------------
-spec new()               -> state().
%% @doc Make a fresh state.
new()                     -> soapbox_obj:new().
new(Lst)                  -> soapbox_obj:from_list(Lst).

-spec to_context(state()) -> context().
to_context(State)         -> meshup_contexts:new(to_obj(State)).

-spec to_obj(state())     -> soapbox_obj:ect().
to_obj(State)             -> soapbox_obj:map(fun latest/1, State).

%%%_  * State -> Ctx ---------------------------------------------------
%% Service methods see only the data items they requested via their
%% input contract, and only the newest version of each item. We call
%% this derived subset of the full state the CONTEXT of a service call.

-spec get(state(), meshup_contracts:contract()) ->
             maybe({state(), context()}, _).
%% @doc Get a context from a state; data items which don't exist in the
%% in-state are imported from storage and included in the out-state.
get(State, Contract) ->
  meshup_contracts:fold(fun do_get/2,
                        {State, meshup_contexts:new()},
                        Contract,
                        to_obj(State)).

do_get({Name, Annotations}, {State0, Ctx}) ->
  State = maybe_import(State0, Name, Annotations),
  case get_value(State, Name) of
    {ok, Term} ->
      {ok, {State, meshup_contexts:set(Ctx, Name, Term)}};
    {error, notfound} ->
      case tulib_lists:assoc(optional, Annotations) of
        {ok, true}  -> {ok, {State, Ctx}};
        {ok, false} -> {error, {missing_input, Name}}
      end
  end;
do_get([], Acc) -> {ok, Acc}.

maybe_import(State, Name, Annotations) ->
  case {get_value(State, Name), tulib_lists:assoc(store, Annotations)} of
    {{error, notfound}, {ok, Store}} -> import(State, Name, Store);
    _                                -> State
  end.

import(State, Name, Store) ->
  ?debug("reading ~p from ~p", [Name, Store]),
  ?increment([Store, reads]),
  case ?time([Store, reads, time], meshup_store:get(Store, Name)) of
    {ok, Res}  ->
      ?debug("read ~p from ~p: ~p", [Name, Store, Res]),
      ?increment([Store, reads, successful]),
      set_value(State, Name, Res, Store);
    {error, notfound} ->
      ?debug("reading ~p from ~p failed: notfound", [Name, Store]),
      ?increment([Store, reads, notfound]),
      State;
    {error, Rsn} ->
      ?warning("reading ~p from ~p failed: ~p", [Name, Store, Rsn]),
      ?increment([Store, reads, failed]),
      State
  end.

%%%_  * Input -> State -------------------------------------------------
-spec init(state(), context()) -> maybe(state(), _).
%% @doc Add some initial data to State.
init(State, Ctx) -> init(State, Ctx, any).

-spec init(state(), context(), meshup_contracts:namespace()) ->
              maybe(state(), _).
init(State, Ctx, NS) -> do_init(meshup_contexts:to_list(Ctx), State, NS).

do_init([{Name, Term}|Rest], State, NS) ->
  ?hence(NS =:= any orelse NS =:= input),
  case meshup_contracts:in_namespace(NS, Name) of
    true  -> do_init(Rest, set_value(State, Name, Term, init), NS);
    false -> {error, {bad_name, Name, NS}}
  end;
do_init([], State, _NS) -> {ok, State}.

%%%_  * Ctx -> State ---------------------------------------------------
-spec set(state(), context(), meshup_contracts:contract()) ->
             maybe(state(), _).
%% @doc Absorb the out-context of a service call back into the current
%% state.
set(State, Output, Contract) ->
  Obj  = meshup_contexts:to_obj(Output),
  Call = meshup_contracts:call(Contract),
  meshup_contracts:fold(fun(Clause, Acc) -> do_set(Clause, Acc, Call) end,
                        {State, Obj},
                        Contract,
                        Obj).

do_set({Name, Annotations}, {State, Output}, Call) ->
  case ?lift(soapbox_obj:get(Output, Name)) of
    {ok, Term} ->
      {ok, { do_set(State, Name, Annotations, Term, Call)
           , soapbox_obj:del(Output, Name)
           }};
    {error, _} ->
      case tulib_lists:assoc(optional, Annotations) of
        {ok, true}  -> {ok, {State, Output}};
        {ok, false} -> {error, {missing_output, Name}}
      end
  end;
do_set([], {State, Output}, _Call) ->
  case soapbox_obj:is_empty(Output) of
    true  -> {ok, State};
    false -> {error, {undeclared_output, soapbox_obj:keys(Output)}}
  end.

do_set(State0, Name, Annotations, Term, SM) ->
  State = set_value(State0, Name, Term, SM),
  case tulib_lists:assoc(store, Annotations) of
    {ok, Store}       -> set_store(State, Name, Store);
    {error, notfound} -> State
  end.

%%%_  * write/1 --------------------------------------------------------
-spec write(state(), meshup_sessions:id(), meshup_sessions:mode()) ->
               maybe(_, _).
%% @doc Write the latest version of every data item in State for which a
%% store has been set to that store. Unfulfilled promises are ignored at
%% this stage. Return success iff ALL of the writes succeed.
write(State, ID, Mode) ->
  tulib_maybe:lift(?thunk(
  %%F          = strat(Mode),
  %%{ok, Rets} = F(do_write(ID), write_set(State)),
  {M, F}          = strat(Mode),
  {ok, Rets} = apply(M, F, [do_write(ID), write_set(State)]),
  []         = [Err || {error, _} = Err <- Rets])).

strat(async)      -> {tulib_par, eval};
strat(in_process) -> {tulib_maybe, map};
strat(write_set)  -> fun(F, WriteSet) ->
                       {ok, [?lift(F({take_store(WriteSet),
                                      write_set,
                                      drop_store(WriteSet)}))]}
                     end.

take_store(WriteSet) ->
  [Store] = lists:usort([Store || {Store, _Name, _Val} <- WriteSet]),
  Store.

drop_store(WriteSet) -> [{Name, Val} || {_Store, Name, Val} <- WriteSet].

write_set(State) ->
  [{Data#data.store, Name, latest_with_meta(Data)} ||
    {Name, Data} <- soapbox_obj:to_list(State), is_writable(Data)].

is_writable(#data{name=Name, store=Store} = Data) ->
  case is_pending(Data) of
    true ->
      ?warning("pending promise: ~p", [Name]),
      ?increment([promises, pending]),
      false;
    false -> is_store(Store)
  end.

is_pending(Data) -> meshup_promises:is_promise(latest(Data)).

do_write(ID) ->
  fun(Write) -> do_write(ID, Write) end.
do_write(ID, {Store, Name, Val}) ->
  ?debug("writing ~p => ~p to ~p", [Name, Val, Store]),
  ?increment([Store, writes]),
  case
    ?time([Store, writes, time],
          meshup_store:put(Store, Name, Val, [{session_id, ID}]))
  of
    ok ->
      ?debug("wrote ~p to ~p", [Name, Store]),
      ?increment([Store, writes, successful]),
      ok;
    {error, Rsn} = Err->
      ?warning("writing ~p to ~p failed: ~p", [Name, Store, Rsn]),
      ?increment([Store, writes, failed]),
      Err
  end.


%% FIXME: just call this from write/3?
%% @doc Replaces promises in State with their values.
%% Blocks until all promises in State have either been fulfilled or
%% expired.
await(State) ->
  ?debug("state is ~p", [State]),
  {ok, Rets} = tulib_par:eval(fun do_await/1, promises(State)),
  ?debug("promise state is ~p", [Rets]),
  fulfill(State, [KV || {ok, KV} <- Rets]). %drop expired promises

promises(State) ->
  soapbox_obj:to_list(
    soapbox_obj:map(fun latest/1,
                    soapbox_obj:filter(fun is_pending/1,
                                       State))).

do_await({Name, Promise}) ->
  case meshup_promises:get(Promise) of %block
    {ok, Res}              -> {ok, {Name, Res}};
    {error, expired} = Err -> Err
  end.

fulfill(State, Fulfilled) ->
  soapbox_obj:map(
    fun(Name, Data) ->
      case tulib_lists:assoc(Name, Fulfilled) of
        {ok, Val} ->
          ?hence(is_pending(Data)),
          update(Data, Val, promise);
        {error, notfound} -> Data
      end
    end, State).

%%%_  * Compression ----------------------------------------------------
compress(State) ->
  soapbox_obj:map(
    fun(#data{vals=[Latest|_]} = Data) ->
      Data#data{vals=term_to_binary([Latest], [compressed])}
    end, State).

uncompress(State) ->
  soapbox_obj:map(
    fun(#data{vals=Vals0} = Data) ->
      [_] = Vals = binary_to_term(Vals0),
      Data#data{vals=Vals}
    end, State).

%%%_  * Resolver -------------------------------------------------------
-spec merge(state(), state()) -> maybe(state(), _).
%% @doc Perform a syntactic merge of two states.
merge(Obj1, Obj2) ->
  ?lift(soapbox_obj:fold(
    fun(Name, Data2, Obj1) ->
      case ?lift(soapbox_obj:get(Obj1, Name)) of
        {ok, Data1} -> soapbox_obj:set(Obj1, Name, do_merge(Data1, Data2));
        {error, _}  -> soapbox_obj:set(Obj1, Name, Data2)
      end
    end, Obj1, Obj2)).

do_merge(#data{name=[meshup, name]} = D,
         #data{name=[meshup, name]}) ->
  D; %XXX
do_merge(#data{name=N, vals=Vs1, store=S1, meta=M1},
         #data{name=N, vals=Vs2, store=S2, meta=M2}) ->
  #data{ name  = N
       , vals  = merge_vals(Vs1, Vs2)
       , store = merge_store(S1, S2)
       , meta  = merge_meta(M1, M2)
       }.

%% One of the histories must be a prefix of the other (we don't handle
%% conflicting updates).
merge_vals(Vs1, Vs2) ->
  lists:reverse(do_merge_vals(lists:reverse(Vs1), lists:reverse(Vs2))).

do_merge_vals([V|Vs1], [V|Vs2]) -> [V|do_merge_vals(Vs1, Vs2)];
do_merge_vals([],      Vs2)     -> Vs2;
do_merge_vals(Vs1,     [])      -> Vs1;
do_merge_vals(Vs1,     Vs2)     -> throw({error, {vals, Vs1, Vs2}}).

%% The store field is write-once.
merge_store(S,  S)  -> S;
merge_store('', S2) -> S2;
merge_store(S1, '') -> S1;
merge_store(S1, S2) -> throw({error, {store, S1, S2}}).

%% Can't replace an imported data item with a computed data item (or the
%% other way around).
merge_meta(M, M)   -> M;
merge_meta(M1, M2) -> throw({error, {meta, M1, M2}}).

%%%_ * Internals -------------------------------------------------------
-spec set_value(state(), name(), _, source()) -> state().
%% @doc Add a new value to State.
set_value(State, Name, Term, Source) ->
  case ?lift(soapbox_obj:get(State, Name)) of
    {error, _} -> soapbox_obj:set(State, Name, create(Name, Term, Source));
    {ok, Data} -> soapbox_obj:set(State, Name, update(Data, Term, Source))
  end.

-spec create(name(), _, source()) -> #data{}.
create(Name, Term0, Source) ->
  case is_store(Source) of
    true ->
      {Term, Meta} = meshup_store:bind(Source, Name, Term0),
      #data{name=Name, vals=[#item{term=Term,  source=Source}], meta=Meta};
    false ->
      #data{name=Name, vals=[#item{term=Term0, source=Source}]}
  end.

-spec update(#data{}, _, source()) -> #data{}.
%% @doc Add a new version to a data item.
%% Promises can only be updated via await/1 above and no value can be
%% changed into a promise.
update(#data{name=Name, vals=[#item{term=T} = First|Rest], store=Store} = Data,
       Term,
       promise) ->
  ?hence(meshup_promises:is_promise(T)),
  ?hence(Rest =:= []),
  [mergeable([Term|terms(Rest)], Name, Store) || is_store(Store)],
  %% Replace promise with value.
  Data#data{vals=[First#item{term=Term}|Rest]};
update(#data{name=Name, vals=[#item{term=T, vsn=Vsn}|_] = Vals, store=Store} = Data,
       Term,
       Source) ->
  ?hence(is_call(Source) orelse Source =:= init),
  ?hence(not meshup_promises:is_promise(Term)),
  ?hence(not meshup_promises:is_promise(T)),
  [mergeable([Term|terms(Vals)], Name, Store) || is_store(Store)],
  Data#data{vals=[#item{term=Term, vsn=Vsn+1, source=Source}|Vals]}.

terms(Items) -> [T || #item{term=T} <- Items].

mergeable(Terms0, Name, Store) ->
  Terms = lists:reverse(Terms0), %\ apply
  lists:foldl(                   %/ oldest-to-newest
    fun(Term, Merged0) ->
      case ?lift(meshup_store:merge(Store, Name, Merged0, Term)) of
        {ok, Merged} ->
          ?debug("merged ~p and ~p locally yielding ~p",
                 [Merged0, Term, Merged]),
          ?increment([local_merges, successful]),
          Merged;
        {error, Rsn} ->
          ?warning("local merge of ~p and ~p failed: ~p",
                   [Merged0, Term, Rsn]),
          ?increment([local_merges, failed]),
          throw({mergeable, Store, Name, Term, Merged0, Rsn})
      end
    end, hd(Terms), tl(Terms)).


-spec set_store(state(), name(), store()) -> store().
%% @doc Record that Name should be written to Store.
%% We ensure that each data item lives in exactly one data store.
set_store(State, Name, Store) ->
  #data{vals=Vals, store=Store_} = Data = soapbox_obj:get(State, Name),
  ?given(is_store(Store_), Store_ =:= Store),
  #item{source=Source} = lists:last(Vals),
  ?given(is_store(Source), Source =:= Store),
  soapbox_obj:set(State, Name, Data#data{store=Store}).


-spec get_value(state(), name()) -> maybe(_, _).
%% @doc Get the current value associated with Name in State.
get_value(State, Name) ->
  case ?lift(soapbox_obj:get(State, Name)) of
    {ok, Data} -> {ok, latest(Data)};
    {error, _} -> {error, notfound}
  end.

latest(#data{vals=[#item{term=Term}|_]}) -> Term.

%% @doc Get the final version of a data item, ready to be written to its
%% data store.
latest_with_meta(#data{ name  = Name
                      , vals  = [#item{term=Term}|_]
                      , store = Store
                      , meta  = Meta
                      }) ->
  case Meta of
    undefined -> meshup_store:return(Store, Name, Term);
    _         -> meshup_store:return(Store, Name, Term, Meta)
  end.


is_store('')   -> false; %#data.store
is_store(init) -> false; %Source
is_store(X)    -> meshup_callbacks:is_callback(X).

is_call(X)     -> meshup_endpoint:is_step(X).

%%%_ * Pretty Printer ==================================================
-spec pp(state()) -> meshup_pp:printable().
pp(State) ->
  meshup_pp:cat(
    [meshup_pp:header("State")] ++
      [pp_data(V) || {_K, V} <- soapbox_obj:to_list(State)]).

pp_data(#data{name=N, vals=Vs, store=S, meta=M}) ->
  meshup_pp:cat(
    [meshup_pp:fmtln("~p (~p:~p) =>", [N, S, M])] ++
      meshup_pp:indent([pp_item(I) || I <- Vs])).

pp_item(#item{term=T, vsn=V, source=S}) ->
  meshup_pp:fmtln("~p (~p): ~p", [V, S, T]).

%%%_* Tests ============================================================
-ifdef(TEST).

service(Store) ->
  meshup_service:make(
    fun(meth1, Ctx) ->
        meshup:ok(
          [ [s, m],        meshup_contexts:get(Ctx, [input, n]) + 1
          , [s, [b1, k1]], 666
          ]);
       (meth2, _Ctx) ->
        P       = meshup_promises:new(10),
        {ok, _} = meshup_promises:set(P, 43),
        meshup:ok(
          [ [s, [b2, k2]], P
          ])
    end,
    fun(meth1, input)  ->
        [ [input, n]
        , {[input, x], [{optional, true}]}
        , {[s, [b0, k0]], [{store, Store}]}
        ];
       (meth1, output) ->
        [ [s, m]
        , {[s, y], [{optional, true}]}
        , {[s, [b1, k1]], [{store, Store}]}
        ];
       (meth2, input)  -> [ ];
       (meth2, output) -> [ [s, [b2, k2]] ]
    end,
    fun() -> s end).

input() -> ?ctx([[input, n], 0]).


basic_test() ->
  Store            = test_store_ets:new(),
  Srvc             = service(Store),
  Input            = input(),

  ok               = meshup_store:put(Store, [s, [b0, k0]], 42),

  S0               = new(),
  {ok, S1}         = init(S0, Input, input),

  {ok, IC1}        = meshup_contracts:parse({Srvc, meth1}, input),
  {ok, {S2, C10}}  = get(S1, IC1),

  {ok, OC1}        = meshup_contracts:parse({Srvc, meth1}, output),
  #return{ctx=C11} = meshup_service:call(Srvc, meth1, C10),
  {ok, S3}         = set(S2, C11, OC1),

  {ok, IC2}        = meshup_contracts:parse({Srvc, meth2}, input),
  {ok, {S4, C20}}  = get(S3, IC2),

  {ok, OC2}        = meshup_contracts:parse({Srvc, meth2}, output),
  #return{ctx=C21} = meshup_service:call(Srvc, meth2, C20),
  {ok, S5}         = set(S4, C21, OC2),

  S                = await(S5),

  {ok, _}          = write(S, 666, async),
  {ok, _}          = write(S, 666, in_process),

  ok               = io:format(user, "~s", [pp(S)]),
  _                = to_context(S),

  ok.


errors_test() ->
  %% Match error - input
  {error, {_, {unmatched_pattern, [foo,{x}]}}} =
    get(new([[bar,foo], #data{vals=[#item{term=42}]}]),
        make_contract([[foo,{x}]], input)),
  %% Match error - output
  {error, {_, {unmatched_pattern, [foo,{x}]}}} =
    set(new(),
        meshup_contexts:new([[bar,foo], 42]),
        make_contract([[foo,{x}]], output)),
  %% Missing input
  {error, {_, {missing_input, [foo,bar]}}} =
    get(new([[bar,foo], #data{vals=[#item{term=42}]}]),
        make_contract([[foo,bar]], input)),
  %% GET error
  {error, {_, {missing_input, [foo,bar]}}} =
    get(new(), make_contract([{[foo,bar], [{store,test_store_ets:new()}]}],
                              input)),
  %% Bad input error
  {error, {bad_name, [foo,bar], _}} =
    init(new(), meshup_contexts:new([[foo,bar],1]), input),
  %% Missing output
  {error, {_, {missing_output, [foo,bar]}}} =
    set(new(), meshup_contexts:new(), make_contract([[foo,bar]], output)),
  %% Undeclared output
  {error, {_, {undeclared_output, _}}} =
    set(new(), meshup_contexts:new([[foo,bar],42]), make_contract([], output)),
  %% Expired promise
  await(new([ [foo,bar], #data{vals=[ #item{term=meshup_promises:new(0)} ]} ])),
  ok.

make_contract(Decl, DeclType) ->
  Srvc = meshup_service:make(
    fun(_, _) -> throw(undefined) end,
    fun(_, Type) ->
      case Type =:= DeclType of
        true  -> Decl;
        false -> throw(undefined)
      end
    end,
    fun() -> foo end),

  %% Cover
  undefined = (catch meshup_service:call(Srvc, foo, bar)),
  undefined = (catch meshup_service:describe(Srvc, foo, bar)),
  []        = meshup_service:props(Srvc, foo),
  infinity  = meshup_service:sla(Srvc, foo),

  SM        = {Srvc, meth},
  {ok, C}   = meshup_contracts:parse(SM, DeclType),
  C.


%% LWW
mergeable_test() ->
  Terms = [v3, v2, v1],
  Store =
    fun({merge, 3}) ->
      fun(_, foo, bar) -> {error, quux};
         (_, _V0, V1)  -> {ok, V1}
      end
    end,
  v3         = mergeable(Terms, name, Store),
  {error, _} = ?lift(mergeable([bar,foo], name, Store)),
  ok.


init_test() ->
  init(new(), ?ctx([[foo,bar], 42])).


update_test() ->
  Source     = {service, method},
  S0         = new(),
  {ok, S1}   = ?lift(set_value(S0, [foo,bar], 42, Source)),
  {ok, S2}   = ?lift(set_value(S1, [foo,bar], 43, Source)),
  {error, _} = ?lift(set_value(S2, [foo,bar], meshup_promises:new(0), Source)),


  {ok, S1__} = ?lift(set_value(S0, [foo,bar], meshup_promises:new(0), Source)),
  {error, _} = ?lift(set_value(S1__, [foo,bar], 42, Source)),

  Store      = test_store_ets:new(),
  {ok, S1_}  = ?lift(set_value(S0,  [foo,bar], 42, Store)),
  {ok, S2_}  = ?lift(set_store(S1_, [foo,bar], Store)),
  {ok, _}    = ?lift(set_value(S2_, [foo,bar], 43, Source)),

  ok.


write_test() ->
  Store      = test_store_ets:new(),
  S0         = new(),
  S1         = set_value(S0, [foo, bar], 42, Store),
  S2         = set_store(S1, [foo, bar], Store),
  S3         = set_value(S2, [foo, baz], meshup_promises:new(0), Store),
  S4         = set_store(S3, [foo, baz], Store),
  {ok, _}    = write(S4, 666, in_process),

  S1_        = set_value(S0,  [fail], 42, Store),
  S2_        = set_store(S1_, [fail], Store),
  {error, _} = write(S2_, 666, async),
  ok.

merge_test() ->
  State1 = soapbox_obj:from_list(
             [ [foo, bar],  #data{vals=[v1,v0], store=foo}
             , [foo, baz],  #data{vals=[v1,v0]}
             ]),
  State2 = soapbox_obj:from_list(
             [ [foo, bar],  #data{vals=[v2,v1,v0]}
             , [foo, baz],  #data{vals=[v0], store=bar}
             , [foo, quux], #data{vals=[v0]}
             ]),
  {ok, State} = merge(State1, State2),
  #data{vals=[v2,v1,v0], store=foo} = soapbox_obj:get(State, [foo, bar]),
  #data{vals=[v1,v0], store=bar} = soapbox_obj:get(State, [foo, baz]),
  #data{vals=[v0]} = soapbox_obj:get(State, [foo, quux]),
  ok.

merge_error_test() ->
  %% Divergent values
  {error, {vals, _, _}} =
    ?lift(merge(
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v1,v0]} ]),
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v2,v0]} ]))),
  %% Divergent stores
  {error, {store, _, _}} =
    ?lift(merge(
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v0], store=foo} ]),
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v0], store=bar} ]))),
  %% Conflicting meta
  {error, {meta, _, _}} =
    ?lift(merge(
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v0], meta=foo} ]),
      soapbox_obj:from_list([ [foo, bar],  #data{vals=[v0], meta=bar} ]))),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
