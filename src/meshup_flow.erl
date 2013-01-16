%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Flow preprocessor.
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
%% @private
-module(meshup_flow).

%%%_* Exports ==========================================================
-export([ annotate/2
        , rewrite/1
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/assert.hrl").
-include_lib("tulib/include/prelude.hrl").

-include("shared.hrl").

%%%_* Macros ===========================================================
-define(MESHUP, meshup).

-define(BLOCK, [?MESHUP, block]).
-define(NAME,  [?MESHUP, name]).

%%%_* Code =============================================================
%% MeshUp support `sessions' - multiple flows operating on the same
%% context. The notation is:
%%
%% [ flow_1
%% , [ {srvc_A, api_X}
%%   , ...
%%   , {srvc_B, api_Y}
%%   ]
%% , ...
%% , flow_N
%% , [ {srvc_I, api_K}
%%   , ...
%%   , {srvc_J, api_L}
%%   ]
%% ]
%%
%% Here, N flows contribute to a session-flow. Each sub-flow has a
%% name, and a sequence of steps. The interface is the usual
%% meshup:start/1,2. In addition to an endpoint, the user provides a
%% label, which names the particular sub-flow to be run.
%% When a sub-flow halts, the session-flow is suspended, and the
%% current context, along with a session ID, is returned to the user.
%% This session ID may later be used to meshup:resume/1 a session-flow,
%% again providing a label to select the sub-flow to run.
%% Eventually, sufficient data to close a session will have accumulated
%% in the context. The user may now choose to meshup:finish/1 the
%% session-flow, which will commit all writes to their respective
%% stores.
rewrite([])                -> [];
rewrite([{_, _}|_] = Flow) -> Flow;
rewrite(X)                 -> do_rewrite(parse(X)).

parse(SessionFlow) ->
  SubFlows = tulib_lists:partition(2, SessionFlow),
  ?hence(lists:all(fun(Xs) -> length(Xs) =:= 2 end, SubFlows)),
  [begin
     ?hence(is_atom(Name)),
     ?hence(is_list(SubFlow)),
     _ = meshup_endpoint:compile(SubFlow), %assert
     {name(Name), SubFlow}
   end || [Name, SubFlow] <- SubFlows].

name(Name) -> tulib_atoms:catenate([?MESHUP, '_', Name]).


%% Context preparation.
annotate(Ctx, undefined) -> meshup_contexts:set(Ctx, ?NAME, undefined);
annotate(Ctx, eof)       -> meshup_contexts:set(Ctx, ?NAME, eof);
annotate(Ctx, Label)     -> meshup_contexts:set(Ctx, ?NAME, name(Label)).

%% We generate a simple flow which implements the semantics described above:
%%
%% [ {?MESHUP, prologue}, [ ?MESHUP_flow_1, '->', {?MESHUP_flow_1, label}
%%                        , ...
%%                        , ?MESHUP_flow_N, '->', {?MESHUP_flow_N, label}
%%                        , eof,            '->', {?MESHUP, eof}
%%                        , block,          '->', {}
%%                        ]
%% , {?MESHUP_flow_1, label}
%% , {srvc_A, api_X}
%% , ...
%% , {srvc_B, api_Y}
%% , {?MESHUP, epilogue}, [ prologue, '<-', {?MESHUP, prologue}
%%                        ]
%% , ...
%% , {?MESHUP_flow_N, label}
%% , {srvc_I, api_K}
%% , ...
%% , {srvc_J, api_L}
%% , {?MESHUP, epilogue}, [ prologue, '<-', {?MESHUP, prologue}
%%                        ]
%% , {?MESHUP, eof}
%% ]
do_rewrite(SubFlows) ->
  SessionService = session_service(),
  gen_head(SubFlows, SessionService) ++
  gen_body(SubFlows, SessionService) ++
  gen_tail(SessionService).


gen_head(SubFlows, SessionService) ->
  [{SessionService, prologue}, gen_tab([Name || {Name, _} <- SubFlows])].

gen_tab(Names) ->
  lists:flatten([[Name, '->', {Name, label}] || Name <- Names]) ++
  [ eof,   '->', {?MESHUP, eof}
  , block, '->', {}
  ].

gen_body(SubFlows, SessionService) ->
  tulib_lists:join(
    [begin
       FlowService = flow_service(Name),
       [{FlowService, label}] ++
       Flow                   ++
       [{SessionService, epilogue}, [prologue, '<-', {?MESHUP, prologue}]]
     end || {Name, Flow} <- SubFlows]).

gen_tail(SessionService) -> [{SessionService, eof}].


session_service() ->
  meshup_service:make(
    fun(prologue, Ctx)    ->
        case meshup_contexts:get(Ctx, ?BLOCK, false) of
          %% Toggle.
          true  -> meshup:error(block, meshup_contexts:new([?BLOCK, false]));
          %% Bad label will abort flow.
          false -> meshup:error(meshup_contexts:get(Ctx, ?NAME))
        end;
       (epilogue, _Ctx)   ->
        meshup:error(prologue, meshup_contexts:new([?BLOCK, true]));
       (eof, Ctx) -> meshup:ok(Ctx) %nop
    end,
    fun(prologue, input)  -> [{?BLOCK, [{optional, true}]}, ?NAME];
       (prologue, output) -> [{?BLOCK, [{optional, true}]}];
       (epilogue, input)  -> [];
       (epilogue, output) -> [{?BLOCK, [{optional, true}]}];
       (eof,      input)  -> [];
       (eof,      output) -> []
    end,
    fun()  -> ?MESHUP  end,
    fun(_) -> []       end,
    fun(_) -> infinity end).

flow_service(Name) ->
  meshup_service:make(
    fun(label, Ctx) -> meshup:ok(Ctx) end, %nop
    fun(label, _)   -> []             end,
    fun()           -> Name           end,
    fun(_)          -> []             end,
    fun(_)          -> infinity       end).

%%%_* Tests ============================================================
-ifdef(TEST).

syntax_test() ->
  meshup_test:with_env(?thunk(
    []    = rewrite([]),
    Flow1 = flow1(),
    Flow1 = rewrite(Flow1),
    Res   = rewrite(flow()),

    [ {_, prologue}, [ meshup_flow1, '->', {meshup_flow1, label}
                     , meshup_flow2, '->', {meshup_flow2, label}
                     , eof,          '->', {meshup, eof}
                     , block,        '->', {}
                     ]
    , {_, label}
    , {test_service_checkout, query_customer}
    , [block, '=>', {}]
    , {test_service_id, identify_customer}
    , [insufficient_data, '<=', {checkout, query_customer}]
    , {_, epilogue}, [ prologue, '<-', {meshup, prologue}
                   ]
    , {_, label}
    , {test_service_risk, score_customer}
    , {test_service_accepted, finalize_purchase}
    , {_, epilogue}, [ prologue, '<-', {meshup, prologue}
                   ]
    , {_, eof}
    ] = Res,

    ok)).

semantics_test() ->
  meshup_test:with_env(?thunk(
    Endpoint = meshup_endpoint:make(?thunk(flow())),
    Input1   = meshup_contexts:new([ [input,goods], [g1,g2,g3]    ]),
    Input2   = meshup_contexts:new([ [input,email], "foo@bar.baz" ]),
    {ok, {suspended, ID, _}} =
      meshup:start([ {endpoint, Endpoint}
                   , {label,    flow1}
                   , {input,    Input1}
                   ]),
    {ok, {suspended, ID, _}} =
      meshup:resume([ {session_id, ID}
                    , {input, Input2}
                    ]),
    {ok, {suspended, ID, _}} =
      meshup:resume([ {session_id, ID}
                    , {input, meshup_contexts:new()}
                    , {label, flow2}
                    ]),
    {ok, _} =
      meshup:finish([ {session_id, ID}
                    ]),
    ok
  )).


flow() ->
  [ flow1
  , flow1()
  , flow2
  , flow2()
  ].

flow1() ->
  [ {test_service_checkout, query_customer}
  , [block, '=>', {}]
  , {test_service_id, identify_customer}
  , [insufficient_data, '<=', {checkout, query_customer}]
  ].

flow2() ->
  [ {test_service_risk, score_customer}
  , {test_service_accepted, finalize_purchase}
  ].

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
