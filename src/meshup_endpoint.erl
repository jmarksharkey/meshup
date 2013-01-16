%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc The MeshUp endpoint behaviour & evaluator.
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
-module(meshup_endpoint).

%%%_* Exports ==========================================================
%% Behaviour
-export([ behaviour_info/1
        , flow/1
        , post_commit/1
        , make/1
        , make/2
        , new/1
        ]).

%% Computations
-export([ context/1
        , hooks/1
        , state/1
        , status/1
        ]).

-export([ compress/1
        , uncompress/1
        ]).

-export([ merge/2
        ]).

%% API
-export([ compile/1
        , eval/1
        , eval/2
        , is_step/1
        ]).

%% Debug/test support
-export([ eval_step/1
        , eval_loop/1
        , eval_resume/2
        , init/2
        ]).

%% Printing
-export([ pp/1
        ]).

-export_type([ computation/0
             , flow/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/logging.hrl").
-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

-include("shared.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type step()    :: {meshup_callbacks:callback(), atom()}.
-type rsn()     :: atom().
-type arrow()   :: '->'
                 | '=>'
                 | '<-'
                 | '<='.
-type handler() :: {atom(), atom()}
                 | {}.

%% Users specify computations in terms of flows which consist of one or
%% more nodes.
%% Each node represents a call to an API of some service.
%% By default, control proceeds serially along the nodes of a flow.
%% This behavior may be overridden by associating a jump table with a
%% node, in which case control may be redirected to another node (the
%% handler) or suspended when certain errors occur.
-type flow_node() :: step()
                   | [rsn() | arrow() | handler()].
-type flow()      :: [flow_node()].

%% Flow declarations are compiled into an IR for a simple evaluator
%% which manages the shared (flow-) state of a computation
-type addr()       :: non_neg_integer().
-type jump_table() :: soapbox_obj:ect(rsn(), {arrow(), addr()}).

%% Each node becomes an instruction. Note that services are queried for
%% meta-information AT COMPILE TIME but the call is dispatched to
%% whichever code is present AT RUN TIME.
-record(inst,
        { label :: handler()                   %
        , call  :: step()                      %As specified in the flow
        , in    :: meshup_contracts:contract() %\  As indicated by the
        , out   :: meshup_contracts:contract() % \ corresponding
        , sla   :: timeout()                   % / meshup_service
        , props :: [_]                         %/  callbacks
        , tab   :: jump_table()                %Compiled jump table
        }).

%% The interpreter state consists of an addressable representation
%% of the flow, a pointer to the current instruction, a
%% return-address stack, and a field which tracks the status of the
%% flow.
-type status() :: ?running
                | ?halted
                | ?suspended
                | {?aborted, _}
                | {?crashed, _}
                | {?timeout, _}.

-record(engine,
        { prog            :: array:array(#inst{})
        , pc=0            :: addr()
        , stack=[]        :: [addr()]
        , trace=[]        :: [addr()] %for debugging
        , status=?running :: status()
        }).

%% A computation consists of the interpreter-state and the flow-state.
-record(computation,
        { engine=throw('#computation.engine') :: #engine{}
        , state=meshup_state:new()            :: meshup_state:state()
        , hooks=throw('#computation.hooks')   :: fun()
        }).

-opaque computation() :: #computation{}.

%%%_ * ADT -------------------------------------------------------------
state(#computation{state=S}) -> S.
status(#computation{engine=#engine{status=S}}) -> S.
context(Computation) -> meshup_state:to_context(state(Computation)).
hooks(#computation{hooks=H}) -> H.

compress(#computation{state=S} = C) ->
    C#computation{state=meshup_state:compress(S)}.

uncompress(#computation{state=S} = C) ->
    C#computation{state=meshup_state:uncompress(S)}.

merge(#computation{engine=E1, state=S1, hooks=H},
      #computation{engine=E2, state=S2, hooks=H}) ->
  ?hence(E1#engine.prog   =:= E2#engine.prog),
  ?hence(E1#engine.pc     =:= E2#engine.pc),
  ?hence(E1#engine.stack  =:= E2#engine.stack),
%%?hence(E1#engine.trace  =:= E2#engine.trace),
  ?hence(E1#engine.status =:= E2#engine.status),
  #computation{ engine = E1#engine{trace=[]}
              , state  = ?unlift(meshup_state:merge(S1, S2))
              , hooks  = H
              }.

%%%_ * Behaviour -------------------------------------------------------
%% -callback flow()        -> flow().
%% -callback post_commit() -> [fun((meshup_contexts:context()) -> _)].

behaviour_info(callbacks) ->
  [ {flow,        0}
  , {post_commit, 0}
  ];
behaviour_info(_) -> undefined.

make(Flow) ->
  make(Flow, fun() -> [] end).
make(Flow, PostCommit) ->
  new([ {flow, 0},        Flow
      , {post_commit, 0}, PostCommit
      ]).

new(Mtab) -> meshup_callbacks:new(Mtab, ?MODULE).

flow(Endpoint)        -> meshup_callbacks:call(Endpoint, flow,        []).
post_commit(Endpoint) -> meshup_callbacks:call(Endpoint, post_commit, []).

%%%_ * Compile ---------------------------------------------------------
-spec compile(meshup_callbacks:callback()) -> #engine{} | no_return().
compile(Endpoint) when ?is_callback(Endpoint) ->
  compile(meshup_flow:rewrite(flow(Endpoint)));
compile(Flow) when is_list(Flow) -> do_compile(parse(Flow)).

-spec parse(flow()) -> flow().
%% @doc Parse flow declaration.
%% A flow is a list of steps/nodes. Each node may be followed by a jump
%% table. Nodes are simply {Service, Method} tuples. The jump table
%% format is described below.
parse([X1, X2|Xs]) ->
  case {is_step(X1), is_step(X2)} of
    {true, true}  -> [{X1, parse_jt([])}|parse([X2|Xs])];
    {true, false} -> [{X1, parse_jt(X2)}|parse(    Xs )];
    _             -> throw({bad_input, X1})
  end;
parse([X]) ->
  case is_step(X) of
    true  -> [{X, parse_jt([])}];
    false -> throw({bad_input, X})
  end;
parse([]) -> [].

is_step({Service, Method}) ->
  meshup_callbacks:is_callback(Service) andalso is_atom(Method);
is_step(_) -> false.

%% Jump Tables look like so:
%%
%%   [ Reason1, '<-', Handler1
%%   , Reason2, '<=', Handler2
%%   , Reason3, '->', Handler3
%%   , Reason4, '=>', Handler4
%%   , ...
%%   ]
%%
%% where the reasons are atoms and the handlers are
%% {ServiceName, Method} tuples. The special '{}' handler will suspend
%% the current computation, pending new input.
%%
%% '->/<-' indicates that execution should jump to the specified
%%   handler and continue from there.
%% '=>/<=' indicates that the specified handler should be called,
%%   i.e. execution should jump to the handler then return to the
%%   current step.
%%
%% The direction of the arrow shows where in the flow the handler may
%% be found; ->/=> points forward in the flow, <-/<= points backward
%% in the flow.
%%
%% N.B. handlers may call other handlers, but not goto other handlers
%% (which would be somewhat tricky to implement given that there's no
%% explicit `return' statement).
parse_jt(Decl) ->
  parse_jt(Decl, soapbox_obj:new()).
parse_jt([Rsn, Arrow, Handler|Rest], Acc) when is_atom(Rsn) ->
  ?hence(is_arrow(Arrow)),
  ?hence(is_handler(Handler)),
  parse_jt(Rest, soapbox_obj:set(Acc, Rsn, {Arrow, Handler}));
parse_jt([], Acc) ->
  Acc;
parse_jt(X, Acc) ->
  throw({bad_input, {X, Acc}}).

is_arrow('->') -> true;
is_arrow('=>') -> true;
is_arrow('<-') -> true;
is_arrow('<=') -> true;
is_arrow(_)    -> false.

is_handler({Name, Method}) -> is_atom(Name) andalso is_atom(Method);
is_handler({})             -> true;
is_handler(_)              -> false.

arrow_direction('->') -> forward;
arrow_direction('=>') -> forward;
arrow_direction('<-') -> backward;
arrow_direction('<=') -> backward.

arrow_type('->') -> goto;
arrow_type('=>') -> call;
arrow_type('<-') -> goto;
arrow_type('<=') -> call.

-spec do_compile(flow()) -> #engine{}.
do_compile(Flow) ->
  {Prog, Addr} =
    lists:foldl(
      fun(Node, {Prog, Addr}) ->
        {array:set(Addr, compile_node(Node), Prog), Addr+1}
      end, {array:new(length(Flow)), 0}, Flow),
  ?hence(array:size(Prog) =:= Addr),
  #engine{prog=fixup(Prog)}.

compile_node({{Service, Method} = Call, Tab}) ->
  Name      = meshup_service:name(Service),
  {ok, In}  = meshup_contracts:parse(Call, input),
  {ok, Out} = meshup_contracts:parse(Call, output),
  SLA       = meshup_service:sla(Service, Method),
  Props     = meshup_service:props(Service, Method),
  #inst{ label = {Name, Method}
       , call  = Call
       , in    = In
       , out   = Out
       , sla   = SLA
       , props = Props
       , tab   = Tab
       }.

%% Resolve handler addresses.
fixup(Prog) -> array:map(fun(Addr, Inst) -> fixup(Addr, Inst, Prog) end, Prog).

fixup(Addr, #inst{tab=Tab} = I, Prog) ->
  I#inst{tab=soapbox_obj:map(fun({_, {}} = X) -> X;
                                ({Arrow, Handler}) ->
                                 {Arrow, resolve(Arrow, Handler, Addr, Prog)}
                             end, Tab)}.

resolve(Arrow, Handler, Addr, Prog) ->
  case arrow_direction(Arrow) of
    backward -> nearest(Handler, Addr, Prog);
    forward  -> nearest(Handler, Addr, Prog, array:size(Prog))
  end.

nearest(Handler, Addr, Prog) when Addr >= 0 ->
  case array:get(Addr, Prog) of
    #inst{label=Handler} -> Addr;
    _                    -> nearest(Handler, Addr-1, Prog)
  end;
nearest(Handler, _, _) -> throw({bad_input, {no_such_handler, Handler}}).

nearest(Handler, Addr, Prog, Size) when Addr < Size ->
  case array:get(Addr, Prog) of
    #inst{label=Handler} -> Addr;
    _                    -> nearest(Handler, Addr+1, Prog, Size)
  end;
nearest(Handler, _, _, _) -> throw({bad_input, {no_such_handler, Handler}}).

%%%_ * Eval ------------------------------------------------------------
eval(Endpoint) ->
  eval(Endpoint, meshup_contexts:new()).

-spec eval(meshup_callbacks:callback(), meshup:context()) -> maybe(_, _)
        ; (computation(),               meshup:context()) -> maybe(_, _).
eval(Endpoint, Input) when ?is_callback(Endpoint) ->
  eval(#computation{ engine = compile(Endpoint)
                   , hooks  = post_commit(Endpoint)
                   },
       Input);
eval(#computation{engine=#engine{status=Status} = E, state=State} =C, Input) ->
  ?hence(Status =:= ?running orelse Status =:= ?suspended),
  eval_loop(C#computation{ engine = E#engine{status=?running}
                         , state  = ?unlift(meshup_state:init(State,
                                                              Input,
                                                              input))
                         }).

-spec eval_loop(computation()) -> computation().
eval_loop(#computation{} = C) ->
  maybe_eval(C, fun(C) -> eval_loop(do_eval(C)) end).

maybe_eval(#computation{engine=E} = C, F) ->
  case E#engine.status of
    ?running -> F(C);
    _        -> C
  end.

do_eval(#computation{engine=E0, state=S0} = C) ->
  %% Given the current state of the computation
  %% we either step, interrupt, or abort the interpreter, depending on
  %% the result of the next call (which gets SLA milliseconds to run).
  #inst{ call = {Service, Method}
       , in   = In
       , out  = Out
       , sla  = SLA
       } = current_inst(E0),
  Name              = case is_atom(Service) of
                        true  -> meshup_service:name(Service);
                        false -> '__generated__'
                      end,
  {ok, {S1, InCtx}} = ?time([Name, get], meshup_state:get(S0, In)),
  ?info("calling ~p:~p()", [Name, Method]),
  {E, S} =
    case
      ?time([Name, Method],
            meshup_lib:call_within(
              ?thunk(meshup_service:call(Service, Method, InCtx)),
              SLA))
    of
      {ok, #return{type=ok, ctx=OutCtx}} ->
        {step(E0), ?unlift(meshup_state:set(S1, OutCtx, Out))};
      {ok, #return{type=error, rsn=Rsn, ctx=undefined}} ->
        {interrupt(E0, Rsn), S1};
      {ok, #return{type=error, rsn=Rsn, ctx=OutCtx}} ->
        {interrupt(E0, Rsn), ?unlift(meshup_state:set(S1, OutCtx, Out))};
      {error, timeout} ->
        {timeout(E0, {Name, Method}), S1};
      {error, Rsn} ->
        {crash(E0, Rsn), S1};
      X ->
        {crash(E0, {bad_return, X}), S1}
    end,
  C#computation{engine=E, state=S}.

%%%_ * Engine ----------------------------------------------------------
%% legal transitions:
%%  suspended -> running
%%  running   -> running

%%  running   -> halted
%%  running   -> suspended
%%  running   -> aborted
%%  running   -> crashed

current_inst(#engine{prog=Prog, pc=PC}) -> array:get(PC, Prog).

step(#engine{prog=Prog, pc=PC0, stack=[], trace=Trace, status=?running} = E) ->
  %% Common case: continue with next instruction.
  PC = PC0 + 1,
  case PC >= array:size(Prog) of
      true  -> E#engine{pc=PC0, status=?halted};
      false -> E#engine{pc=PC, trace=[PC0|Trace]}
  end;
step(#engine{pc=PC, stack=[Addr|Addrs], trace=Trace, status=?running} = E) ->
  E#engine{pc=Addr, stack=Addrs, trace=[PC|Trace]}. %pop

%% Note that the error table is assumed to only contain valid
%% addresses, and that handlers are assumed to exist.
interrupt(#engine{pc=PC, stack=Stack, trace=Trace, status=?running} = E, Rsn) ->
  #inst{tab=Tab} = current_inst(E),
  case soapbox_obj:get(Tab, Rsn, undefined) of
    undefined     -> E#engine{status={?aborted, Rsn}};
    {_, {}}       -> E#engine{status=?suspended};
    {Arrow, Addr} ->
      case arrow_type(Arrow) of
        call -> E#engine{pc=Addr, stack=[PC|Stack], trace=[PC|Trace]}; %push
        goto -> ?hence(Stack =:= []), E#engine{pc=Addr, trace=[PC|Trace]}
      end
  end.

timeout(#engine{status=?running} = E, Rsn) -> E#engine{status={?timeout, Rsn}}.
crash(#engine{status=?running} = E, Rsn) -> E#engine{status={?crashed, Rsn}}.

%%%_ * Debug & test support --------------------------------------------
init(Endpoint, Ctx) ->
  #computation{ engine = compile(Endpoint)
              , state  = ?unlift(meshup_state:init(meshup_state:new(), Ctx))
              , hooks  = post_commit(Endpoint)
              }.

eval_step(C) -> maybe_eval(C, fun(C) -> do_eval(C) end).

eval_resume(#computation{engine=E, state=S} = C, Ctx) ->
  case E#engine.status of
    ?suspended ->
      C#computation{ engine=E#engine{status=?running}
                   , state=?unlift(meshup_state:init(S, Ctx, input))
                   };
    _ -> C
  end.

%%%_ * Pretty Printer --------------------------------------------------
-spec pp(computation()) -> meshup_pp:printable().
pp(#computation{engine=E, state=S}) ->
  meshup_pp:cat(
   [meshup_pp:header("Engine")]
    ++ pp_engine(E)
    ++ [meshup_pp:fmtln("")]
    ++ [meshup_state:pp(S)]).

pp_engine(#engine{prog=Prog, pc=PC, stack=Stack, status=Status}) ->
  [meshup_pp:fmtln("Stack: ~p",
                   [[tulib_atoms:catenate([f, N]) || N <- Stack]])]
    ++ [meshup_pp:fmtln("Status: ~p", [Status])]
    ++ pp_prog(Prog, PC).

pp_prog(Prog, PC) ->
  lists:reverse(
    array:foldl(
      fun(Idx, Inst, Acc) ->
        [pp_inst(Inst, Idx, PC, array:size(Prog) - 1)|Acc]
      end, [], Prog)).

pp_inst(#inst{call={Service0, API}, tab=Tab}, Idx, PC, Size) ->
  Service = meshup_service:name(Service0),
  case soapbox_obj:is_empty(Tab) of
    true  -> pp_inst(Service, API,      Idx, PC, Size);
    false -> pp_inst(Service, API, Tab, Idx, PC, Size)
  end.

pp_inst(Service, API, Idx, PC, Size) ->
  meshup_pp:cat(
    [case Idx =:= Size of
       true ->
         meshup_pp:fmt("f~p(X) -> ~p:~p(X).", [Idx, Service, API]);
       false ->
         meshup_pp:fmt("f~p(X) -> f~p(~p:~p(X)).", [Idx, Idx+1, Service, API])
     end]
    ++ [meshup_pp:fmt(" %<<<") || Idx =:= PC]
    ++ [meshup_pp:fmtln("")]).

pp_inst(Service, API, Tab, Idx, PC, Size) ->
  meshup_pp:cat(
    [meshup_pp:fmt("f~p(X) ->", [Idx])]
    ++ [meshup_pp:fmt(" %<<<") || Idx =:= PC]
    ++ [meshup_pp:fmtln("")]
    ++ meshup_pp:indent(
         [meshup_pp:fmtln("case ~p:~p(X) of", [Service, API])]
         ++ meshup_pp:indent(
              case Idx =:= Size of
                true  -> [meshup_pp:fmtln("{ok, Res} -> Res", [])];
                false -> [meshup_pp:fmtln("{ok, Res} -> f~p(Res)", [Idx+1])]
              end
              ++ pp_tab(Tab))
         ++ [meshup_pp:fmtln("end.")])).

pp_tab(Tab) ->
  [meshup_pp:fmtln("{error, ~p} -> ~p(f~p)", [Rsn, Type, Addr]) ||
    {Rsn, {Type, Addr}} <- soapbox_obj:to_list(Tab)].

%%%_* Tests ============================================================
-ifdef(TEST).

%%%_ * Basics ----------------------------------------------------------
basic_test() ->
  Computation0 = eval(e0()),
  ok           = io:format(user, "~s~n", [pp(Computation0)]),
  ?suspended   = status(Computation0),
  Computation  = eval(Computation0, i0()),
  ?halted      = status(Computation),
  ok           = io:format(user, "~s~n", [pp(Computation)]),
  Ctx          = context(Computation),
  []           = hooks(Computation),
  46           = meshup_contexts:get(Ctx, [s2, result]),
  ok.

e0() ->
  make(fun() ->
    [ {s0(), s0_api0}, []
    , {s1(), s1_api0}, [ meh,   '<=', {s0, s0_api0}
                       , block, '=>', {}
                       , snarf, '=>', {s2, s2_api0} %FIXME: Is this
                       , snarf, '->', {s2, s2_api0} %what we want?
                       ]
    , {s2(), s2_api0}, [quux, '->', {s2, s2_api1}]
    , {s2(), s2_api1}
    ]
  end).

s0() ->
  meshup_service:make(
    fun(s0_api0, Ctx) ->
      tulib_maybe:cps(
        fun()     -> meshup_contexts:get(Ctx, [s1, v1]) end,
        fun(S1V1) -> meshup:ok([ [s0, v1], S1V1+1 ])    end,
        fun(_)    -> meshup:ok([ [s0, v0], 1      ])    end)
    end,
    fun(s0_api0, input)  -> [ {[s1, v1], [{optional, true}]} ];
       (s0_api0, output) -> [ {[s0, v0], [{optional, true}]}
                            , {[s0, v1], [{optional, true}]}
                            ]
    end,
    fun() -> s0 end).

s1() ->
  meshup_service:make(
    fun(s1_api0, Ctx) ->
      tulib_maybe:cps(
        fun() -> meshup_contexts:get(Ctx, [input, i0]) end,
        fun(I0) ->
            tulib_maybe:cps(
              fun() -> meshup_contexts:get(Ctx, [s0, v1]) end,
              fun(S0V1) -> meshup:ok([ [s1, v0], I0+S0V1 ]) end,
              fun(_) -> meshup:error(meh, [ [s1, v1], 42 ]) end)
        end,
        fun(_) -> meshup:error(block) end)
    end,
    fun(s1_api0, input)  -> [ {[input, i0], [{optional, true}]}
                            , {[s0, v1],    [{optional, true}]}
                            ];
       (s1_api0, output) -> [ {[s1, v0], [{optional, true}]}
                            , {[s1, v1], [{optional, true}]}
                            ]
    end,
    fun() -> s1 end).

s2() ->
  meshup_service:make(
    fun(s2_api0, Ctx) ->
        S0V0 = meshup_contexts:get(Ctx, [s0, v0]),
        S1V0 = meshup_contexts:get(Ctx, [s1, v0]),
        meshup:error(quux, [[s2,result], S0V0 + S1V0]);
       (s2_api1, Ctx) -> meshup:ok(Ctx)
    end,
    fun(s2_api0, input)  -> [ [s0, v0]
                            , [s1, v0]
                            ];
       (s2_api0, output) -> [ [s2, result] ];
       (s2_api1, _)      -> [ ]
    end,
    fun() -> s2 end).

i0() -> meshup_contexts:new([[input, i0], 2]).

%%%_ * Misc ------------------------------------------------------------
misc_test() ->
  []        = parse([]),
  _         = parse([ {s,a}, {s,a} ]),
  undefined = behaviour_info(foo),
  _         = init(e0(), i0()),
  ok.

pp_test() ->
  io:format(user, "~s~n", [pp( init(e1(), meshup_contexts:new()) )]),
  io:format(user, "~s~n", [pp_engine(#engine{ prog   = array:new()
                                            , stack  = [4,0]
                                            , status = ?suspended
                                            })]),
  ok.

e1() ->
  make(fun() ->
    [ {s0(), s0_api0}
    , {s1(), s1_api0}
    , {s2(), s2_api0}, [meh, '<=', {s0,s0_api0}]
    ]
  end).

arrow_test() ->
  true     = is_arrow('=>'),
  true     = is_arrow('<-'),
  forward  = arrow_direction('=>'),
  backward = arrow_direction('<-'),
  call     = arrow_type('=>'),
  goto     = arrow_type('<-'),
  ok.

%%%_ * Errors ----------------------------------------------------------
error_test() ->
  %% Parse
  {bad_input, _} = (catch parse([[]])),
  {bad_input, _} = (catch parse([[], {s,a}])),
  %% Jump table compilation
  {bad_input, {no_such_handler,_}} = (catch eval(e2())),
  %% Bad Retries
  {error, {assert, _, _, _}} = (catch eval(eval(e3()))),
  %% Abort
  {?aborted, foo} = status(eval(e4())),
  %% Halted
  C = eval(e3()),
  C = eval_step(C),
  C = eval_resume(C, meshup_contexts:new()),
  %% Bad service
  {?crashed, {bad_return, {ok, foo}}} = status(eval(e5())),
  %% Timeout
  {?timeout, _} = status(eval(e6())),
  foo = meshup_service:call(s6(), s6_api0, frob), %cover
  %% %% Crash
  {?crashed, {lifted_exn, foo, _}} = status(eval(e7())),
  %% Bad handler
  {error, {assert, _, _, _}} =
    (catch compile(make(fun() ->
     [ {s1(),s1_api0}, [baz, '->', {quux}] ] end))),
  %% Bad arrow
  {error, {assert, _, _, _}} =
    (catch compile(make(fun() ->
     [ {s1(),s1_api0}, [baz, '-->', {quux,snarf}] ] end))),
  %% nonexistant fwd handler
  {bad_input, {no_such_handler, _}} =
    (catch compile(make(fun() ->
     [ {s1(),s1_api0}, [baz, '->', {quux,snarf}] ] end))),
  %% bad input
  {error, {assert, _, _, _}} =
    (catch compile(make(fun() ->
     [ [baz, '->', {quux,snarf}] ] end))),
  %% bad table
  {bad_input, _} =
    (catch compile(make(fun() ->
     [ {s1(),s1_api0}, [baz, '->'] ] end))),
  ok.

e2() -> make(fun() -> [{s1(), s1_api0}, [meh, '<=', {s0,s0_api0}]] end).


e3() -> make(fun() -> [{s3(), s3_api0}] end).

s3() ->
  meshup_service:make(
    fun(s3_api0, _Ctx) -> meshup:ok([]) end,
    fun(s3_api0, input)  -> [];
       (s3_api0, output) -> []
    end,
    fun() -> s3 end).


e4() -> make(fun() -> [{s4(), s4_api0}] end).

s4() ->
  meshup_service:make(
    fun(s4_api0, _Ctx) -> meshup:error(foo) end,
    fun(s4_api0, input)  -> [];
       (s4_api0, output) -> []
    end,
    fun() -> s4 end).


e5() -> make(fun() -> [{s5(), s5_api0}] end).

s5() ->
  meshup_service:make(
    fun(s5_api0, _Ctx) -> foo end,
    fun(s5_api0, input)  -> [];
       (s5_api0, output) -> []
    end,
    fun() -> s5 end).


e6() -> make(fun() -> [{s6(), s6_api0}] end).

s6() ->
  meshup_service:make(
    fun(s6_api0, _Ctx) -> foo end,
    fun(s6_api0, input)  -> [];
       (s6_api0, output) -> []
    end,
    fun() -> s6 end,
    fun(_) -> [] end,
    fun(_) -> 0 end
   ).

e7() -> make(fun() -> [{s7(), s7_api0}] end).

s7() ->
  meshup_service:make(
    fun(s7_api0, _Ctx) -> throw(foo) end,
    fun(s7_api0, input)  -> [];
       (s7_api0, output) -> []
    end,
    fun() -> s7 end
   ).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
