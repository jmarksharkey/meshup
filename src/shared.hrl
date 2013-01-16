%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Shared header file.
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

-define(TULIB_METRICS_PREFIX, meshup).
-include_lib("tulib/include/metrics.hrl").

%% Name
-define(APP, meshup).

%% Returns
-record(return,
        { type :: ok | error
        , rsn  :: _
        , ctx  :: meshup_contexts:context()
        }).

%% Misc
-define(is_callback(X), (is_atom(X) orelse is_function(X, 1))).

-define(running,   '__running__').
-define(suspended, '__suspended__').
-define(halted,    '__halted__').
-define(aborted,   '__aborted__').
-define(crashed,   '__crashed__').
-define(timeout,   '__timeout__').

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
