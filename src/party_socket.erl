-module(party_socket).
-behaviour(gen_server).
-include("party.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {endpoint, socket}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Endpoint) ->
    gen_server:start_link(?MODULE, [Endpoint], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Endpoint]) ->
    {_Protocol, Domain, Port} = party:endpoint(Endpoint),

    gproc_pool:add_worker(
      party:pool_name(party:endpoint(Endpoint)), self()),

    %% TODO: ssl
    case gen_tcp:connect(?b2l(Domain), Port, [{active, false}], 5000) of
        {ok, Socket} ->
            gproc_pool:connect_worker(
              party:pool_name(party:endpoint(Endpoint)), self()),

            {ok, #state{endpoint = Endpoint,
                        socket = Socket}};
        Error ->
            {stop, Error}
    end.


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
