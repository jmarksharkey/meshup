%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Mock endpoint.
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
-module(test_endpoint).
-behaviour(meshup_endpoint).

%%%_* Exports ==========================================================
-export([ flow/0
        , post_commit/0
        ]).

%%%_* Includes =========================================================
%%-include_lib("").

%%%_* Code =============================================================
flow() ->
  [ {test_service_checkout, query_customer}
  , [block, '=>', {}]

  , {test_service_id, identify_customer}
  , [insufficient_data, '<=', {checkout, query_customer}]

  , {test_service_risk, score_customer}

  , {test_service_accepted, finalize_purchase}
  ].

post_commit() -> [].

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
