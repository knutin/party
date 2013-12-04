-module(party_socket_sup).
-behaviour(supervisor).

-export([start_link/0, connect/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
    Child = {party_socket, {party_socket, start_link, []},
             temporary, brutal_kill, worker, []},
    {ok, {{simple_one_for_one, 0, 1}, [Child]}}.


connect(Endpoint) ->
    supervisor:start_child(?MODULE, [Endpoint]).
