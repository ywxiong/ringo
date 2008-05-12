-module(ringo_indexdomain).
-behaviour(gen_server).

-define(IBLOCK_SIZE, 10000).
-define(KEYCACHE_LIMIT, 5 * 1024 * 1024).

% - cur_iblock is the currently active index (iblock), as returned by 
%    ringo_index:new_dex()
% - cur_size is the number of entries in the current index
% - cur_start is the offset in the DB to the first entry in the
%   current index
% - cur_offs is the end offset in the DB to the latest entry in the
%   current index
-record(index, {cur_iblock, cur_size, cur_start, cur_offs, iblocks, db,
        cache_type, cache, domain, home, dbname, cache_limit}).

-export([start_link/4, init/1, handle_call/3, handle_cast/2, handle_info/2, 
         terminate/2, code_change/3]).

% TODO: Make test that gradually builds index (several iblocks) with put requests,
% then deletes iblocks and re-creates them with scan_iblocks. The resulting
% files should be identical.

% Starting the domain index: In the worst case index needs to be rebuilt from
% scratch during initialization of the index server. This can take tens of
% seconds but start_link returns instantly anyway. However, this means that
% requests to the server will be queued until re-indexing finishes.

% Enable nodelay on sockets!

start_link(Domain, Home, DBName, Options) ->
        S = case gen_server:start_link(ringo_indexdomain, 
                        [Domain, Home, DBName, Options], []) of
                {ok, Server} -> Server;
                {error, {already_started, Server}} -> Server
        end,
        gen_server:cast(S, initialize),
        {ok, S}.

init([Domain, Home, DBName, Options]) ->
        error_logger:info_report({"Index opens for", DBName, Options}),
        {CacheType, Cache} = case {
                proplists:get_value(keycache, Options, false),
                proplists:get_value(noindex, Options, false)} of
                        {_, true} -> {none, none};
                        {true, false} -> {key, {dict:new(), lrucache:new()}};
                        {false, false} -> {iblock, []}
                end,
        CacheLimit = ringo_util:get_iparam("KEYCACHE_LIMIT", ?KEYCACHE_LIMIT),
        
        {ok, DB} = bfile:fopen(DBName, "r"),
        {ok, #index{cur_iblock = ringo_index:new_dex(),
                   cur_size = 0,
                   cur_start = 0,
                   cur_offs = 0,
                   cache_type = CacheType,
                   cache_limit = CacheLimit,
                   cache = Cache,
                   domain = Domain,
                   db = DB,
                   home = Home,
                   dbname = DBName
        }}.

handle_call(_, _, D) -> {reply, error, D}.

handle_cast({get, Key, From}, #index{cache_type = iblock, db = DB,
        cache = Cache, cur_iblock = Current, home = Home} = D) ->
        
        Hash = ringo_index:dexhash(Key),
        Offsets = lists:flatten([begin
                {_, L} = ringo_index:find_key(Hash, Iblock), L
        end || Iblock <- lists:reverse([Current|Cache])]),
        send_entries(Offsets, From, DB, Home, Key),
        {noreply, D};

handle_cast({get, Key, From}, #index{cache_type = key,
        home = Home, db = DB} = D) ->
        
        {Lst, D0} = keycache_get(Key, D),
        Offsets = lists:flatten([ringo_index:decode_poslist(P) || P <- Lst,
                is_bitstring(P)]),
        send_entries(Offsets, From, DB, Home, Key),
        {noreply, D0};

handle_cast({get, _, _}, #index{cache_type = none,
        home = _Home, db = _DB} = D) ->
        {noreply, D};

handle_cast({put, _, _, _}, #index{cache_type = none} = D) ->
        {noreply, D};

% ignore entries that were already indexed during initialization
handle_cast({put, _, Pos, _}, #index{cur_offs = Offs} = D) when Pos < Offs ->
        {noreply, D};
                
handle_cast({put, Key, Pos, EndPos}, #index{cur_iblock = Iblock,
        cur_size = Size} = D) ->
        
        %error_logger:info_report({"Add pos", Pos, EndPos, "start", O}),

        NIblock = ringo_index:add_item(Iblock, Key, Pos),
        %error_logger:info_report({"Added"}),
        {noreply, save_iblock(D#index{cur_iblock = NIblock,
                cur_offs = EndPos, cur_size = Size + 1})};


handle_cast(initialize, #index{home = Home} = D) ->
        % Find existing iblocks in the domain's home directory
        Cands = lists:keysort(1, [X || X <- lists:map(fun(F) ->
                case string:tokens(F, "-") of
                        [_, S, E, _] ->
                                {list_to_integer(S), list_to_integer(E), F};
                        _ -> error_logger:warning_report(
                                {"Invalid iblock file", F}), none
                end
        end, filelib:wildcard("iblock-*", Home)), is_tuple(X)]),
        
        % Find out how much of the index the existing iblocks cover. StartPos
        % denotes the last byte covered by an iblock (holes are not allowed
        % in the coverage).
        {Iblocks, StartPos} = lists:mapfoldl(fun
                ({S, E, F}, Pos) when S == Pos -> {F, E};
                (_, Pos) -> {none, Pos}
        end, 0, Cands),
        error_logger:info_report({"Iblocks", Iblocks, "StartPOS", StartPos}),
        {noreply, index_iblock(D#index{iblocks = Iblocks, cur_offs = StartPos},
                ?IBLOCK_SIZE)}.

index_iblock(D, N) when N < ?IBLOCK_SIZE -> D;
index_iblock(#index{dbname = DBName, cur_offs = StartPos} = D, _) ->
        {N, Dex, EndPos} = ringo_index:build_index(
                DBName, StartPos, ?IBLOCK_SIZE),
        error_logger:info_report({"Build index N", N, "EndPos", EndPos}),
        D0 = save_iblock(D#index{cur_iblock = Dex, cur_start = StartPos,
                cur_offs = EndPos}),
        index_iblock(D0, N).

% reply to save_iblock's put request
handle_info({ringo_reply, _, _}, D) ->
        {noreply, D}.

%%%
%%% Send entries, one by one, to the requester
%%%

send_entries(Offsets, From, DB, Home, Key) ->
        % Offsets should be in increasing order to benefit most from read-ahead
        % buffering and page caching.
        lists:foreach(fun(Offset) ->
                case ringo_index:fetch_entry(DB, Home, Key, Offset) of
                        {_Time, _Key, Value} -> From ! {entry, Value};
                        % ignore corruped entries -- might not be wise
                        invalid_entry -> ok;
                        ignore -> ok
                end
        end, Offsets),
        From ! done.

%%%
%%% Iblock becomes full
%%%

save_iblock(#index{cur_size = Size} = D) when Size < ?IBLOCK_SIZE -> D;
save_iblock(#index{cur_iblock = Iblock, cur_start = Start, cur_offs = End,
        iblocks = Iblocks, domain = Domain} = D) ->
        
        error_logger:info_report({"Iblock full!"}),

        Key = iolist_to_binary(io_lib:format("iblock-~b-~b", [Start, End])),
        SIblock = iolist_to_binary(ringo_index:serialize(Iblock)),
        gen_server:cast(Domain, {put, Key, SIblock, [iblock], self()}),
        D0 = update_cache(SIblock, D),
        error_logger:info_report({"Iblock full! ok"}),
        D0#index{cur_start = End, cur_iblock = ringo_index:new_dex(),
                 cur_size = 0, iblocks = Iblocks ++ [Key]}.
        

update_cache(SIblock, #index{cache_type = iblock, cache = Cache} = D) ->
        D#index{cache = [SIblock|Cache]};

update_cache(SIblock, #index{cache_type = key, cache = {Cache, LRU}} = D) ->
        D#index{cache = {dict:map(fun(Key, Offsets) ->
                {_, L} = ringo_index:find_key(Key, SIblock, false),
                Offsets ++ L
        end, Cache), LRU}}.
       
%%%
%%% Keycache
%%%

keycache_get(Key, #index{cache = {Cache, _}} = D) ->
        update_keycache(Key, dict:find(Key, Cache), D).

% cache hit
update_keycache(Key, {ok, {Sze, Lst}}, #index{cache = {Cache, LRU}} = D) ->
        {Lst, D#index{cache = {Cache, lrucache:update({Key, Sze}, LRU)}}};

% cache miss
update_keycache(Key, error, #index{home = Home, cur_iblock = Current,
        iblocks = Iblocks, cache = {Cache, _}} = D) ->

        %error_logger:info_report({"CP 1", Key}),
        Sze = dict:fold(fun(K, {_, V}, S) ->
                S + entry_size(K, V)
        end, 0, Cache),
        %error_logger:info_report({"CP 2"}),
        KeyOffsets = keycache_newentry(Key, Iblocks, Current, Home),
        %error_logger:info_report({"CP 3"}),
        EntrySize = entry_size(Key, KeyOffsets),
        %error_logger:info_report({"CP 4"}),
        D0 = keycache_evict(Sze, EntrySize, D),
        %error_logger:info_report({"CP 5"}),
        {Cache0, LRU0} = D0#index.cache,
        CacheValue = {EntrySize, KeyOffsets}, 
        update_keycache(Key, {ok, CacheValue}, D0#index{cache = 
                {dict:store(Key, CacheValue, Cache0), LRU0}}).

keycache_newentry(Key, Iblocks, Current, Home) ->
        Hash = ringo_index:dexhash(Key),
        {_, CL} = ringo_index:find_key(Hash, Current, false),
        lists:map(fun(IblockFile) ->
                Path = filename:join(Home, binary_to_list(IblockFile)),
                case ringo_reader:read_file(Path) of
                        {ok, Iblock} -> {_, L} = ringo_index:find_key(
                                Hash, Iblock, false), L;
                        _ -> []
                end
        end, Iblocks) ++ [CL].

keycache_evict(CacheSze, EntrySze, #index{cache_limit = Limit} = D)
        when CacheSze + EntrySze < Limit -> D;

keycache_evict(CacheSze, EntrySze, #index{cache = {Cache, LRU}} = D) ->
        X = lrucache:get_lru(LRU),
        if X == nil -> D;
        true ->
                {{Key, Sze}, LRU0} = X, 
                keycache_evict(CacheSze - Sze, EntrySze, D#index{cache =
                        {dict:erase(Key, Cache), LRU0}})
        end.

% Calculate cache size. 64 is an approximate cost in bytes  to upkeep a key
% in the cache
entry_size(K, V) -> entry_size0(size(K) + 64, V).
entry_size0(S, []) -> S;
entry_size0(S, [X|R]) when is_bitstring(X) ->
        entry_size0(S + size(bin_util:pad(X)), R);
entry_size0(S, [X|R]) when is_binary(X) ->
        entry_size0(S + size(X), R);
entry_size0(S, [_|R]) ->
        entry_size0(S, R).

%%%
%%%
%%%

terminate(_Reason, #index{db = DB}) -> bfile:fclose(DB).
code_change(_OldVsn, State, _Extra) -> {ok, State}.

