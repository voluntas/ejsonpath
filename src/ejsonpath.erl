%%% Copyright 2013 Sergey Prokhorov
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.

%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% Created : 12 Aug 2013 by Sergey Prokhorov <me@seriyps.ru>

-module(ejsonpath).

-export([execute/2, execute/3]).

-export_type([json_node/0, jsonpath_funspec/0, jsonpath_fun/0]).

-record(
   context,
   {root,
    set=[],
    functions=[]}).


-type jsonpath() :: string().
-type json_node() :: null                           % null
                     | boolean()                    % true/false
                     | binary()                     % string
                     | number()                     % int/float
                     | [json_node()]                % array
                     | {[{binary(), json_node()}]}. % hash (object)

-type jsonpath_funspec() :: {Name::binary(), Fun::jsonpath_fun()} .
-type jsonpath_fun() :: fun(({CurrentNode::json_node(), RootDoc::json_node()}, Args::[any()]) ->
                                   Return::json_node()).


execute(Path, Doc) ->
    execute(Path, Doc, []).

map_to_list(Map) when is_map(Map) ->
    {[ {K, map_to_list(V)} || {K,V} <- maps:to_list(Map) ]};
map_to_list(L) when is_list(L) ->
    [ map_to_list(V) || V <- L ];
map_to_list(V) ->
    V.

list_to_map({List}) when is_list(List) ->
    maps:from_list([ {K1, list_to_map(V1)} || {K1, V1} <- List]);
list_to_map(List) when is_list(List) ->
    [ list_to_map(E) || E <- List];
list_to_map(V) -> V.

-spec execute(jsonpath(), json_node(), [jsonpath_funspec()]) -> [json_node()].
execute(Path, Doc, Functions) ->
    {ok, Tokens, _} = ejsonpath_scan:string(Path),
    % error_logger:info_msg("Tokens: ~p~n", [Tokens]),

    {ok, Tree} = ejsonpath_parse:parse(Tokens),
    % error_logger:info_msg("Tree: ~p~n", [Tree]),
    case is_map(Doc) of
        false ->
            Context = #context{root=Doc, set=[], functions=Functions};
        true ->
            Context = #context{root=map_to_list(Doc), set=[], functions=Functions}
    end,

    %% try
    #context{set=Result} = execute_tree(Tree, Context),
    case is_map(Doc) of
        false -> Result;
        true -> list_to_map(Result)
    end.
    %% catch Class:Reason ->
    %%         io:format(user, "~p~n~p~n~p~n",
    %%                   [Class, Reason, erlang:get_stacktrace()]),
    %%         {error, Class, Reason, erlang:get_stacktrace()}
    %% end.

execute_tree({root, {steps, Steps}}, #context{root=Root} = Ctx) ->
    execute_step(Steps, Ctx#context{set=[Root]}).

execute_step([{child, {refine, Predicate}} | Next], #context{set=NodeList}=Ctx) ->
    NewNodeList = lists:foldl(
                    fun(Elem, Acc) ->
                            AppendList = apply_predicate(Predicate, Elem, element_type(Elem), Ctx),
                            Acc ++ AppendList   %TODO: optimize
                    end, [], NodeList),
    execute_step(Next, Ctx#context{set=NewNodeList});
execute_step([], Ctx) ->
    Ctx.


apply_predicate(Key, {Pairs}, hash, _Ctx) when is_binary(Key) ->
    case proplists:get_value(Key, Pairs) of
        undefined -> [];
        Value -> [Value]
    end;
apply_predicate(Key, _, _, _Ctx) when is_binary(Key) ->
    [];
apply_predicate({index_expr, Script}, Hash, hash, Ctx) ->
    Key = eval_script(Script, Hash, Ctx),
    apply_predicate(Key, Hash, hash, Ctx);
apply_predicate({index_expr, Script}, L, array, Ctx) ->
    Idx = eval_script(Script, L, Ctx),
    apply_predicate({slice_list, [Idx]}, L, array, Ctx);
apply_predicate({bin_expr, Script}, {Pairs}, hash, Ctx) ->
    [V || {_K, V} <- Pairs, boolean_value(eval_script(Script, V, Ctx))];
apply_predicate({bin_expr, Script}, L, array, Ctx) ->
    [V || V <- L, boolean_value(eval_script(Script, V, Ctx))];
apply_predicate({slice_list, Items}, L, array, _Ctx) ->
    slice_list(Items, L, length(L));
apply_predicate({slice_list, Items}, {Pairs}, hash, _Ctx) ->
    %% FIXME: don't insert undefined when key missing!
    [proplists:get_value(K, Pairs)
    || K <- Items];
apply_predicate({slice, Begin, End, Step}, L, array, _Ctx) ->
    slice_step(Begin, End, Step, L);
apply_predicate('*', {Pairs}, hash, _Ctx) ->
    [V || {_K, V} <- Pairs];
apply_predicate('*', L, array, _Ctx) ->
    L.

eval_script(Key, _, _) when is_binary(Key) ->
    Key;
eval_script(Idx, _, _) when is_number(Idx) ->
    Idx;
eval_script({function_call, Name, Args}, CurNode, #context{functions=Funs, root=Root}) ->
    Fun = proplists:get_value(Name, Funs),
    Fun({CurNode, Root}, Args);
eval_script({bin_op, '==', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X == Y end);
eval_script({bin_op, '!=', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X /= Y end);
eval_script({bin_op, '>', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X > Y end);
eval_script({bin_op, '=<', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X =< Y end);
eval_script({bin_op, '>=', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X >= Y end);
eval_script({bin_op, '<', L, R}, CurNode, Ctx) ->
    eval_binary_op(L, R, CurNode, Ctx, fun(X, Y) -> X < Y end);
eval_script({bin_op, Op, _L, _R}, _, _) ->
    error({not_implemented, bin_op, Op});
eval_script({steps, Steps}, CurNode, Ctx) ->
    #context{set=Set} = execute_step(Steps, Ctx#context{set=[CurNode]}),
    Set;
eval_script('@', CurNode, _Ctx) ->
    CurNode.

eval_binary_op(LScript, RScript, CurNode, Ctx, Op) ->
    case {eval_script(LScript, CurNode, Ctx), eval_script(RScript, CurNode, Ctx)} of
        {[L], [R]} -> Op(L, R);
        { L,  [R]} -> Op(L, R);
        {[L],  R } -> Op(L, R);
        { L,   R } -> Op(L, R)
    end.

%% comma-slices for arrays
%% [1,2,-1,4]
slice_list([Idx | Rest], L, Len) when Idx < 0 ->
    NewIdx = Len + Idx,
    slice_list([NewIdx | Rest], L, Len);
slice_list([Idx | Rest], L, Len) ->
    %% そもそも ID が存在しない場合の処理が入っていない
    case length(L) of
        Length when Length >= (Idx + 1) ->
            [lists:nth(Idx + 1, L) | slice_list(Rest, L, Len)];
        _ ->
            []
    end;
slice_list([], _, _) ->
    [].

%% python slices for arrays
%% [1:-2:1]
slice_step(Begin, End, S, L) when (Begin < 0) ->
    %% [-5:]
    slice_step(max(length(L) + Begin, 0), End, S, L);
slice_step(Begin, End, S, L) when (End < 0) ->
    %% [:-5]
    Len = length(L),
    slice_step(Begin, min(Len + End, Len), S, L);
slice_step(Begin, End, 1, L) when (Begin >= 0) and (End >= 0) ->
    lists:sublist(L, Begin + 1, Begin + End);
slice_step(_Begin, _End, _Step, _L) ->
    error({not_implemented, slice}).

%% type casts
boolean_value([]) ->
    false;
boolean_value({[]}) ->
    false;
boolean_value(<<>>) ->
    false;
boolean_value(undefined) ->
    false;
boolean_value(null) ->
    false;
boolean_value(0.0) ->
    false;
boolean_value(0) ->
    false;
boolean_value(false) ->
    false;
boolean_value(_) ->
    true.



element_type(L) when is_list(L) ->
    array;
element_type({L}) when is_list(L) ->
    hash;
%% element_type({_, _}) ->
%%     hash_pair;
element_type(Bin) when is_binary(Bin) ->
    string;
element_type(Num) when is_number(Num) ->
    number;
element_type(Bool) when is_boolean(Bool) ->
    boolean;
element_type(null) ->
    null.
