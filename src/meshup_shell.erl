%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc The MeshUp REPL.
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
-module(meshup_shell).

%%%_* Exports ==========================================================
-export([ repl/1
        , repl/2
        ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("tulib/include/prelude.hrl").

%%%_* Code =============================================================
%%%_ * REPL ------------------------------------------------------------
-record(repl,
        { it :: meshup_endpoint:computation()
        }).

repl(Endpoint) ->
  repl(Endpoint, []).
repl(Endpoint, Lit) ->
  loop(#repl{it=meshup_endpoint:init(Endpoint, meshup_contexts:new(Lit))}).

loop(Repl) -> try loop(eval(read(), Repl))
              catch throw:quit -> bye
              end.

read() -> string:tokens(io:get_line('meshup> '), " \n").

eval(["help"],       R0) ->                 say(help()),    R0;
eval(["print"],      R0) ->                 say(print(R0)), R0;
eval(["step"],       R0) -> R = step(R0),   say("ok"),      R;
eval(["resume"|Ctx], R0) -> case resume(R0, Ctx) of
                              {ok, R}    -> say("ok"),      R;
                              {error, _} -> say("?"),       R0
                            end;
eval(["finish"],     R0) -> R = finish(R0), say("ok"),      R;
eval(["quit"],       _)  -> throw(quit);
eval(_,              R0) ->                 say("?"),       R0.

say(Words) -> io:format(user, "~s~n", [Words]).

help() ->
  "help       -- print this message\n"
  "print      -- pretty-print the current computation\n"
  "step       -- perform the next step in the current computation\n"
  "resume CTX -- resume a suspended computation with input CTX\n"
  "finish     -- run the current computation to completion\n"
  "quit       -- exit the MeshUp shell\n".

print(#repl{it=It}) ->
  meshup_endpoint:pp(It).
step(#repl{it=It} = R) ->
  R#repl{it=meshup_endpoint:eval_step(It)}.
resume(#repl{it=It} = R, Input) ->
  tulib_maybe:'-?>'(lists:concat(Input),
    [ fun tulib_util:consult_string/1
    , fun meshup_contexts:new/1
    , fun(Ctx) -> R#repl{it=meshup_endpoint:eval_resume(It, Ctx)} end
    ]).
finish(#repl{it=It} = R) ->
  R#repl{it=meshup_endpoint:eval_loop(It)}.

%%%_ * Debugger --------------------------------------------------------
%% -record(mdb,
%%         { it :: meshup_endpoint:computation()
%%         }).

%% mdb(Computation) ->
%%  mdb_loop((#mdb{it=Computation})

%% loop(Repl) -> try loop(eval(read(), Repl))
%%               catch throw:quit -> bye
%%               end.

%% read() -> string:tokens(io:get_line('meshup> '), " \n").

%% eval(["help"],       R0) ->                 say(help()),    R0;
%% eval(["print"],      R0) ->                 say(print(R0)), R0;
%% eval(["step"],       R0) -> R = step(R0),   say("ok"),      R;
%% eval(["resume"|Ctx], R0) -> case resume(R0, Ctx) of
%%                               {ok, R}    -> say("ok"),      R;
%%                               {error, _} -> say("?"),       R0
%%                             end;
%% eval(["finish"],     R0) -> R = finish(R0), say("ok"),      R;
%% eval(["quit"],       _)  -> throw(quit);
%% eval(_,              R0) ->                 say("?"),       R0.

%% say(Words) -> io:format(user, "~s~n", [Words]).

%% help() ->
%%   "help       -- print this message\n"
%%   "print      -- pretty-print the current computation\n"
%%   "step       -- perform the next step in the current computation\n"
%%   "resume CTX -- resume a suspended computation with input CTX\n"
%%   "finish     -- run the current computation to completion\n"
%%   "quit       -- exit the MeshUp shell\n".

%% print(#repl{it=It}) ->
%%   meshup_endpoint:pp(It).
%% step(#repl{it=It} = R) ->
%%   R#repl{it=meshup_endpoint:eval_step(It)}.
%% resume(#repl{it=It} = R, Input) ->
%%   tulib_maybe:'-?>'(lists:concat(Input),
%%     [ fun tulib_util:consult_string/1
%%     , fun meshup_contexts:new/1
%%     , fun(Ctx) -> R#repl{it=meshup_endpoint:eval_resume(It, Ctx)} end
%%     ]).
%% finish(#repl{it=It} = R) ->
%%   R#repl{it=meshup_endpoint:eval_loop(It)}.





%%%_* Tests ============================================================
-ifdef(TEST).
glorious_leader(Commands) -> spawn(?thunk(glorious_leader_loop(Commands))).

glorious_leader_loop([Cmd|Cmds]) ->
  receive
    {io_request, From, ReplyAs, {get_line, _, _}} ->
      From ! {io_reply, ReplyAs, Cmd},
      glorious_leader_loop(Cmds)
  end;
glorious_leader_loop([]) -> ok.

shell(Leader) ->
  Self = self(),
  spawn(?thunk(
    true = group_leader(Leader, self()),
    bye  = repl(test_endpoint, [[input, goods], [stuff, more_stuff]]),
    tulib_processes:send(Self, done))).

basic_test() ->
  meshup_test:with_env(?thunk(
    Leader = glorious_leader(
               [ "help\n"
               , "stpe\n"
               , "step\n"
               , "step\n"
               , "step\n"
               , "resume [[input, email], \"foo@bar.baz\"\n"
               , "resume [[input, email], \"foo@bar.baz\"]\n"
               , "step\n"
               , "print\n"
               , "finish\n"
               , "quit\n"
               ]),
    Shell = shell(Leader),
    {ok, done} = tulib_processes:recv(Shell),
    ok)).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
