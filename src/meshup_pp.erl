%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc MeshUp Pretty Printer.
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
-module(meshup_pp).

%%%_* Exports ==========================================================
-export([ cat/1
        , fmt/1
        , fmt/2
        , fmtln/1
        , fmtln/2
        , header/1
        , indent/1
        ]).

-export_type([ printable/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Code =============================================================
-type printable()             :: string().

-spec fmt(string())           -> printable().
fmt(Msg)                      -> fmt(Msg, []).
fmtln(Msg)                    -> fmtln(Msg, []).

-spec fmt(string(), [_])      -> printable().
fmt(Fmt, Args)                -> tulib_strings:fmt(Fmt, Args).
fmtln(Fmt, Args)              -> tulib_strings:fmt(Fmt ++ "~n", Args).


-spec header(string())        -> printable().
header(H)                     -> fmt("~s~n~s~n", [H, hsep(length(H))]).

-spec hsep(non_neg_integer()) -> printable().
hsep(N)                       -> lists:duplicate(N, $=).


-spec cat([printable()])      -> printable().
cat(Xs)                       -> lists:concat(Xs).

-spec indent([printable()])   -> printable().
indent(Xs)                    -> ["  " ++ X || X <- Xs].

%%%_* Tests ============================================================
-ifdef(TEST).

basic_test() ->
  Str =
    cat([ header("MYHEADER")
        , fmtln("ohai")
        , indent([ fmt("foo")
                 , fmtln("bar")
                 , fmt("baz")
                 , fmtln("snarf")
                 ])
        , fmtln("blarg")
        , fmtln("")
        ]),
  io:format(user, "~s", [Str]),
  ok.

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
