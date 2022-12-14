%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2022. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(mnesia_porset).

-behaviour(mnesia_backend_type).

%% Initializations
-export([init_backend/0, add_aliases/1, remove_aliases/1, check_definition/4,
         semantics/2]).
-export([create_table/3, load_table/4, delete_table/2, close_table/2, sync_close_table/2,
         sender_init/4, receiver_first_message/4, receive_data/5, receive_done/4,
         index_is_consistent/3, is_index_consistent/2, real_suffixes/0, tmp_suffixes/0, info/3,
         fixtable/3, validate_key/6, validate_record/6, first/2, last/2, next/3, prev/3, slot/3,
         insert/3, update_counter/4, lookup/3, delete/3, match_delete/3, select/1, select/3,
         select/4, repair_continuation/2]).
-export([register/0, register/1]).

-define(DEBUG, 1).

-ifdef(DEBUG).

-define(DBG(DATA), io:format("~p:~p: ~p~n", [?MODULE, ?LINE, DATA])).
-define(DBG(FORMAT, ARGS), io:format("~p:~p: " ++ FORMAT, [?MODULE, ?LINE] ++ ARGS)).

-else.

-define(DBG(DATA), ok).
-define(DBG(FORMAT, ARGS), ok).

-endif.


-type op() :: write | delete.
-type val() :: any().
-type ts() :: mnesia_causal:vclock().


%% types() ->
%%     [{fs_copies, ?MODULE},
%%      {raw_fs_copies, ?MODULE}].


%%% convenience functions

register() ->
    register(default_alias()).

register(Alias) ->
    Module = ?MODULE,
    case mnesia:add_backend_type(Alias, Module) of
        {atomic, ok} ->
            {ok, Alias};
        {aborted, {backend_type_already_exists, _}} ->
            {ok, Alias};
        {aborted, Reason} ->
            {error, Reason}
    end.

%%% mnesia_backend_type callbacks

semantics(porset_copies, storage) ->
    ram_copies;
semantics(porset_copies, types) ->
    [set, ordered_set, bag];
semantics(porset_copies, index_types) ->
    [ordered];
semantics(_Alias, _) ->
    undefined.

%% valid_op(_, _) ->
%%     true.

init_backend() ->
    lager:debug(init_backend),
    %% cheat and stuff a marker in mnesia_gvar
    mnesia_porset_admin:ensure_started().

default_alias() ->
    porset_copies.

add_aliases(_As) ->
    lager:debug("add_aliases(~p)", [_As]),
    mnesia_porset_admin:ensure_started(),
    % TODO add alias
    ok.

remove_aliases(_) ->
    % TODO remove alias
    ok.

%% Table operations

check_definition(porset_copies, _Tab, _Nodes, _Props) ->
    lager:debug("~p ~p ~p~n", [_Tab, _Nodes, _Props]),
    ok.

create_table(porset_copies, Tab, Props) when is_atom(Tab) ->
    Tid = ets:new(Tab, [public, proplists:get_value(type, Props, set), {keypos, 2}]),
    lager:debug("~p Create: ~p(~p) ~p~n", [self(), Tab, Tid, Props]),
    mnesia_lib:set({?MODULE, Tab}, Tid),
    ok;
create_table(_, Tag = {Tab, index, {_Where, Type0}}, _Opts) ->
    Type =
        case Type0 of
            ordered ->
                ordered_set;
            _ ->
                Type0
        end,
    Tid = ets:new(Tab, [public, Type]),
    ?DBG("~p(~p) ~p~n", [Tab, Tid, Tag]),
    mnesia_lib:set({?MODULE, Tag}, Tid),
    ok;
create_table(_, Tag = {_Tab, retainer, ChkPName}, _Opts) ->
    Tid = ets:new(ChkPName, [set, public, {keypos, 2}]),
    ?DBG("~p(~p) ~p~n", [_Tab, Tid, Tag]),
    mnesia_lib:set({?MODULE, Tag}, Tid),
    ok.

delete_table(porset_copies, Tab) ->
    try
        ets:delete(
            mnesia_lib:val({?MODULE, Tab})),
        mnesia_lib:unset({?MODULE, Tab}),
        ok
    catch
        _:_ ->
            ?DBG({double_delete, Tab}),
            ok
    end.

load_table(porset_copies, _Tab, init_index, _Cs) ->
    ok;
load_table(porset_copies, _Tab, _LoadReason, _Cs) ->
    ?DBG("Load ~p ~p~n", [_Tab, _LoadReason]),
    ok.

%%     mnesia_monitor:unsafe_create_external(Tab, porset_copies, ?MODULE, Cs).

sender_init(Alias, Tab, _RemoteStorage, _Pid) ->
    KeysPerTransfer = 100,
    {standard,
     fun() -> mnesia_lib:db_init_chunk({ext, Alias, ?MODULE}, Tab, KeysPerTransfer) end,
     fun(Cont) -> mnesia_lib:db_chunk({ext, Alias, ?MODULE}, Cont) end}.

receiver_first_message(Sender, {first, Size}, _Alias, Tab) ->
    ?DBG({first, Size}),
    {Size, {Tab, Sender}}.

receive_data(Data, porset_copies, Name, Sender, {Name, Tab, Sender} = State) ->
    ?DBG({Data, State}),
    true = ets:insert(Tab, Data),
    {more, State};
receive_data(Data, Alias, Tab, Sender, {Name, Sender}) ->
    receive_data(Data, Alias, Tab, Sender, {Name, mnesia_lib:val({?MODULE, Tab}), Sender}).

receive_done(_Alias, _Tab, _Sender, _State) ->
    ?DBG({done, _State}),
    ok.

close_table(Alias, Tab) ->
    sync_close_table(Alias, Tab).

sync_close_table(porset_copies, _Tab) ->
    ?DBG(_Tab).

fixtable(porset_copies, Tab, Bool) ->
    ?DBG({Tab, Bool}),
    ets:safe_fixtable(
        mnesia_lib:val({?MODULE, Tab}), Bool).

info(porset_copies, Tab, Type) ->
    ?DBG({Tab, Type}),
    Tid = mnesia_lib:val({?MODULE, Tab}),
    try ets:info(Tid, Type) of
        Val ->
            Val
    catch
        _:_ ->
            undefined
    end.

real_suffixes() ->
    [".dat"].

tmp_suffixes() ->
    [].

%% Index

index_is_consistent(_Alias, _Ix, _Bool) ->
    ok.  % Ignore for now

is_index_consistent(_Alias, _Ix) ->
    false.      % Always rebuild

%% Record operations

validate_record(_Alias, _Tab, RecName, Arity, Type, _Obj) ->
    {RecName, Arity, Type}.

validate_key(_Alias, _Tab, RecName, Arity, Type, _Key) ->
    {RecName, Arity, Type}.

insert(Alias, Tab, {Obj, Ts}) ->
    io:format("running my own insert function~p~n", [Alias]),
    lager:debug({Tab, Obj}),
    try
        ets:insert(
            mnesia_lib:val({?MODULE, Tab}), {Obj, Ts, write}),
        ok
    catch
        _:Reason ->
            io:format("CRASH ~p ~p~n", [Reason, mnesia_lib:val({?MODULE, Tab})])
    end.

lookup(porset_copies, Tab, Key) ->
    io:format("running my own lookup function~n"),
    ets:lookup(
        mnesia_lib:val({?MODULE, Tab}), Key).

delete(porset_copies, Tab, {Key, Ts}) ->
    ets:insert(
        mnesia_lib:val({?MODULE, Tab}), {Key, Ts, delete}).

match_delete(porset_copies, Tab, Pat) ->
    ets:match_delete(
        mnesia_lib:val({?MODULE, Tab}), Pat).

first(porset_copies, Tab) ->
    ets:first(
        mnesia_lib:val({?MODULE, Tab})).

last(Alias, Tab) ->
    first(Alias, Tab).

next(porset_copies, Tab, Key) ->
    ets:next(
        mnesia_lib:val({?MODULE, Tab}), Key).

prev(Alias, Tab, Key) ->
    next(Alias, Tab, Key).

slot(porset_copies, Tab, Pos) ->
    ets:slot(
        mnesia_lib:val({?MODULE, Tab}), Pos).

update_counter(porset_copies, Tab, C, Val) ->
    ets:update_counter(
        mnesia_lib:val({?MODULE, Tab}), C, Val).

select('$end_of_table' = End) ->
    End;
select({porset_copies, C}) ->
    ets:select(C).

select(Alias, Tab, Ms) ->
    Res = select(Alias, Tab, Ms, 100000),
    select_1(Res).

select_1('$end_of_table') ->
    [];
select_1({Acc, C}) ->
    case ets:select(C) of
        '$end_of_table' ->
            Acc;
        {New, Cont} ->
            select_1({New ++ Acc, Cont})
    end.

select(porset_copies, Tab, Ms, Limit) when is_integer(Limit); Limit =:= infinity ->
    ets:select(
        mnesia_lib:val({?MODULE, Tab}), Ms, Limit).

repair_continuation(Cont, Ms) ->
    ets:repair_continuation(Cont, Ms).


%%% pure op-based orset implementation

% -spec obsolete({ts(), {op(), val()}}, {ts(), {op(), val()}}) -> boolean().
% obsolete({Ts1, {write, V1}}, {Ts2, {write, V1}}) ->
%     V1 =:= V2 andalso mnesia_causal:compare_vclock(Ts1 < Ts2) =:= lt;
% obsolete({Ts1, {write, V1}}, {Ts2, {delete, V2}}) ->
%     V1 =:= V2 and also mnesia_causal:compare_vclock(Ts1 < Ts2) =:= lt; 
% obsolete({Ts1, {delete, V1}}, _X) ->
%     true.

