%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Macros for use in EUnit tests.
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

-define(flowReturns(Flow, Ret),
        ?flowReturns(Flow, [], Ret)).
-define(flowReturns(Flow, Opts, Ret),
        ?flowReturns(Flow, Opts, Ret, fun() -> true end)).
-define(flowReturns(Flow, Opts, Ret, Assert),
        ?endpointReturns(meshup_endpoint:make(?thunk(Flow)), Opts, Ret, Assert)).

-define(endpointReturns(Ep, Ret),
        ?endpointReturns(Ep, [], Ret)).
-define(endpointReturns(Ep, Opts, Ret),
        ?endpointReturns(Ep, Opts, Ret, fun() -> true end)).
-define(endpointReturns(Ep, Opts, Ret, Assert),
        meshup_test:with_env(?thunk(
          Ret = meshup:start([{endpoint, Ep}|Opts]),
          Assert()))).

-define(ctx(Lst), meshup_contexts:new(Lst)).

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
