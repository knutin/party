%% @doc: Parallel http client
-module(party).
-include("party.hrl").
-export([connect/2, get/3, post/4]).

-export([pool_name/1, endpoint/1]).

connect(Endpoint, NumConnections) ->
    case gproc_pool:new(pool_name(endpoint(Endpoint)), claim,
                        [{size, NumConnections}]) of
        ok ->
            try
                lists:foreach(fun (_) ->
                                      case party_socket_sup:connect(Endpoint) of
                                          {ok, _} ->
                                              ok;
                                          Error ->
                                              throw({connect_error, Error})
                                      end
                              end, lists:seq(1, NumConnections)),
                ok
            catch
                throw:{connect_error, Error} ->
                    {error, {connect, Error}}
            end
    end.

get(URL, Headers, Opts) ->
    do({get, URL, Headers, Opts}, timeout(Opts)).

post(URL, Headers, Body, Opts) ->
    do({post, URL, Headers, Body, Opts}, timeout(Opts)).


do(Request, Timeout) ->
    Req = fun ({n, l, [gproc_pool, {party_socket, _}, _, Pid]}, _) ->
                  party_socket:do(Pid, Request, Timeout)
          end,
    case gproc_pool:claim(pool_name(endpoint(url(Request))), Req) of
        {true, Res} ->
            Res;
        false ->
            {error, max_concurrency}

    end.


%%
%% HELPERS
%%

endpoint(<<"http://", DomainPortPath/binary>>) ->
    DomainPort = case binary:split(DomainPortPath, <<"/">>) of
                     [D] -> D;
                     [D, _Path] -> D
                 end,

    case binary:split(DomainPort, <<":">>) of
        [Domain] ->
            {tcp, Domain, 80};
        [Domain, Port] ->
            {tcp, Domain, ?b2i(Port)}
    end.

url({get, URL, _, _})     -> URL;
url({post, URL, _, _, _}) -> URL.


pool_name({_Protocol, _Domain, _Port} = Endpoint) ->
    {party_socket, Endpoint}.

timeout(Opts) -> proplists:get_value(timeout, Opts, 5000).
    
