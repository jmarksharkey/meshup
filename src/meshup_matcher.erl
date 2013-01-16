%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Pattern matcher.
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
-module(meshup_matcher).

%%%_* Exports ==========================================================
-export([ match/2
        ]).

-export_type([ obj/0
             ]).

%%%_* Includes =========================================================
-include_lib("eunit/include/eunit.hrl").

-include_lib("tulib/include/prelude.hrl").
-include_lib("tulib/include/types.hrl").

%%%_* Code =============================================================
%%%_ * API -------------------------------------------------------------
-type name()    :: meshup_contracts:name().
-type pattern() :: meshup_contract:pattern().

-type obj()     :: soapbox_obj:ect(name(), _).
-type env()     :: alist(meshup_contracts:var(), meshup_contracts:const()).

-spec match([pattern()], obj()) -> maybe([pattern()|name()], _).
match(Pats, Obj) ->
  tulib_maybe:lift(?thunk(
    %% This environment contains bindings for variables occuring in names
    %% which don't contain any substitutions, names which contain
    %% substitutions with constant targets, and names which contain
    %% substitutions with variable targets which only contain variables
    %% for which bindings happened to be calculated before they were
    %% reached.
    Env0 = match(Pats, Obj, env_new()),

    %% This environment contains bindings for variables occuring in names
    %% which, when replacing the variables with their bindings and
    %% substitutions with the values of their targets, match some key of
    %% Obj.
    %% Notice that we have to run the matcher a second time to ensure that
    %% we have established bindings for variables occuring in variable
    %% substitution targets, but we don't have to compute a fixpoint
    %% because substitution targets may not contain further substitutions.
    Env = match(Pats, Obj, Env0),

    %% Instatiate as many patterns as we can given the final environment.
    eval(Pats, Obj, Env))).

%%%_ * Matching --------------------------------------------------------
-spec match([pattern()], obj(), env()) -> env().
%% @doc Construct an environment in which (a subset of) the Pats match
%% one of the keys in Obj.
%%
%% We do not assume that all of the Pats can be matched against one of
%% the names. Pats which do not match any of the names do not contribute
%% any bindings to the returned environment.
%%
%% Binding conflicts are resolved greedily, i.e. the pattern which
%% occurs first in Pats will contribute its bindings whereas any later
%% patterns which could be matched using different bindings for shared
%% variables won't contribute anything.
%%
%% We raise an exception if a pattern matches more than one name.
match(Pats, Obj, Env) ->
  %% The left-fold into the environment establishes precedence of
  %% earlier bindings over later bindings (c.f. match_var/3).
  lists:foldl(fun(Pat, Env) -> do_match(Pat, Obj, Env) end, Env, Pats).

-spec do_match(pattern(), obj(), env()) -> env() | no_return().
%% @doc Extend Env0 such that Pat matches one of the keys of Obj.
do_match(Pat, Obj, Env0) ->
  case
    tulib_maybe:partition([?lift(do_match(Pat, Name, Obj, Env0)) ||
                            Name <- soapbox_obj:keys(Obj)])
  of
    {[Env],           _} -> Env;
    {[_, _|_] = Envs, _} -> throw({multi_match, Pat, Obj, Envs});
    {[],              _} -> Env0 %no match
  end.

-spec do_match(pattern(), name(), obj(), env()) -> env() | no_return().
%% @doc Match a single primitive pattern against a single name.
do_match([P|Pat], [N|Name], Obj, Env) ->
  do_match(Pat, Name, Obj, do_match1(P, N, Obj, Env));
do_match([], [], _, Env) ->
  Env;
do_match(_, _, _, _) ->
  throw(nomatch).

do_match1(Name, Name, _Obj, Env) ->
  Env;
do_match1(Pat, Name, Obj, Env)
  when is_list(Pat)
     , is_list(Name) ->
  do_match(Pat, Name, Obj, Env);
do_match1(Pat, Name, Obj, Env) ->
  case {meshup_contracts:is_var(Pat), meshup_contracts:is_subst(Pat)} of
    {true, false}  -> match_var(Pat, Name, Env);
    {false, true}  -> match_subst(Pat, Name, Obj, Env);
    {false, false} -> throw(nomatch)
  end.

match_var(Var, Name, Env) ->
  case env_lookup(Env, Var) of
    {ok, Name}        -> Env;
    {ok, _X}          -> throw(nomatch); %first binding wins
    {error, notfound} -> env_insert(Env, Var, Name)
  end.

match_subst(Subst, Name, Obj, Env0) ->
  Pat = meshup_contracts:subst_target(Subst),
  Env = match([Pat], Obj, Env0),
  case eval_subst(Subst, Obj, Env) of
    Name -> Env;
    _    -> throw(nomatch)
  end.

%%%_ * Evaluation ------------------------------------------------------
-spec eval([pattern()], obj(), env()) -> [pattern()|name()].
%% @doc Return the names represented by Pats given variable-environment
%% Env and substitution-environment Obj. Note that we may not be able to
%% evaluate all patterns.
eval(Pats, Obj, Env) -> [do_eval(Pat, Obj, Env) || Pat <- Pats].

-spec do_eval(pattern(), obj(), env()) -> name() | no_return().
%% @doc Instantiate a single pattern.
do_eval(Pat, Obj, Env) -> [do_eval1(P, Obj, Env) || P <- Pat].

do_eval1(Pat, Obj, Env) when is_list(Pat) ->
  do_eval(Pat, Obj, Env);
do_eval1(Pat, Obj, Env) ->
  case
    { meshup_contracts:is_const(Pat)
    , meshup_contracts:is_var(Pat)
    , meshup_contracts:is_subst(Pat)
    }
  of
    {true,  false, false} -> Pat;
    {false, true,  false} -> eval_var(Pat, Env);
    {false, false, true}  -> eval_subst(Pat, Obj, Env)
  end.

eval_var(Var, Env) ->
  case env_lookup(Env, Var) of
    {ok, Name}        -> Name;
    {error, notfound} -> Var
  end.

eval_subst(Subst, Obj, Env) ->
  F    = meshup_contracts:subst_fun(Subst),
  Pat  = meshup_contracts:subst_target(Subst),
  Name = do_eval(Pat, undefined, Env), %assert no recursive substitutions
  case ?lift(soapbox_obj:get(Obj, Name)) of
    {ok, Val}  -> F(Val);
    {error, _} -> Subst
  end.

%%%_ * Environments ----------------------------------------------------
env_new()                     -> [].
env_lookup(Env, Var)          -> tulib_lists:assoc(Var, Env).
env_insert(Env, Var, Binding) -> [{Var, Binding}|Env].

%%%_* Tests ============================================================
-ifdef(TEST).

-define(obj(L), soapbox_obj:from_list(L, fun(_, _) -> true end)).

const_test() ->
  {ok, Names} = match([[foo, bar]], ?obj([[foo, bar],  1])),
  ?assertEqual(Names, [[foo, bar]]).

tuple_const_test() ->
  {ok, Names} = match([[{foo, bar}]], ?obj([[{foo, bar}],  1])),
  ?assertEqual(Names, [[{foo, bar}]]).

var_test() ->
  {ok, Names} = match([[foo, {x}]], ?obj([[foo, bar],  1])),
  ?assertEqual(Names, [[foo, bar]]).

shared_var_test() ->
  {ok, Names} = match([ [foo, {x}]
                      , [bar, {x}]
                      ],
                      ?obj([ [foo, bar], 1
                           , [bar, bar], 2
                           ])),
  ?assertEqual(Names, [[foo, bar], [bar, bar]]).

subst_internals_test() ->
  ?assertEqual(match_subst({{[foo,bar]}}, baz, ?obj([[foo,bar],baz]), env_new()),
               env_new()),
  ?assertEqual(eval_subst({{[foo,bar]}}, ?obj([[foo,bar],baz]), env_new()),
               baz).

const_subst_test() ->
  {ok, Names} = match([ [foo, bar]
                      , [bar, {{[foo, bar]}}]
                      ],
                      ?obj([ [foo, bar], 1
                           , [bar, 1],   2
                           ])),
  ?assertEqual(Names, [[foo, bar], [bar, 1]]).

var_subst_test() ->
  {ok, Names} = match([ [foo, {x}]
                      , [bar, {{[foo, {x}]}}]
                      ],
                      ?obj([ [foo, bar], 1
                           , [bar, 1],   2
                           ])),
  ?assertEqual(Names, [[foo, bar], [bar, 1]]).

bind_subst_test() ->
  {ok, Names} = match([ [foo, bar]
                      , [bar, {{[foo, {x}]}}]
                      ],
                      ?obj([ [foo, bar], 1
                           , [bar, 1],   2
                           ])),
  ?assertEqual(Names, [[foo, bar], [bar, 1]]).

no_const_match_test() ->
  {ok, Names} = match([[foo, bar]], ?obj([[foo, baz],  1])),
  ?assertEqual(Names, [[foo,bar]]).

%% Are these the semantics we're looking for?
first_match_wins_test() ->
  {ok, Names} = match([ [foo, {x}]
                      , [bar, {x}]
                      ],
                      ?obj([ [foo, bar], 1
                           , [bar, baz], 3
                           ])),
  ?assertEqual(Names, [[foo,bar],[bar,bar]]).

bad_var_match_test() ->
  {ok, Names} = match([[foo, {x}]], ?obj([[baz, quux],  1])),
  ?assertEqual(Names, [[foo, {x}]]).

multi_match_test() ->
  {error, _} = match([ [foo, {x}]
                     , [bar, {y}]
                     ],
                     ?obj([ [foo, bar], 1
                          , [foo, baz], 2
                          , [bar, baz], 3
                          ])).

complex_pattern_test() ->
  {ok, Names} = match([ [foo, {x}, bar, [baz, [[{y}, {x}]]]]
                      , [bar, {y}, {z}]
                      ],
                      ?obj([ [foo, bar, bar, [baz, [[quux, bar]]]], 1
                           , [bar, quux, [snarf, blarg]],           2
                           ])),
  ?assertEqual(Names, [ [foo, bar, bar, [baz, [[quux, bar]]]]
                      , [bar, quux, [snarf, blarg]]
                      ]).

cornercases_test() ->
  Env         = env_new(),
  Env         = match([[foo,{x}]], ?obj([[foo,bar,baz],42]), Env),
  {ok, Names} = match([[foo,{{[bar,baz]}}]], ?obj([[foo,0],42])),
  ?assertEqual(Names, [ [foo,{{[bar,baz]}}] ]).

subst_fun_test() ->
  {ok, Names} = match([[foo,{{fun(X) -> X * 2 end, [bar,baz]}}]],
                      ?obj([ [bar,baz], 2])),
  ?assertEqual(Names, [[foo, 4]]).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
