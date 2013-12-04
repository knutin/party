%% @doc: Parallel http client
-module(party).
-include("party.hrl").
-export([connect/2, get/3, post/4]).

-export([pool_name/1, endpoint/1]).

connect(Endpoint, NumConnections) ->
    case gproc_pool:new(pool_name(endpoint(Endpoint)), claim,
                        [{size, NumConnections}]) of
        ok ->
            error_logger:info_msg(
              "created pool ~p~n",
              [pool_name(endpoint(Endpoint))]),

            [party_socket_sup:connect(Endpoint)
             || _ <- lists:seq(1, NumConnections)]
    end.

get(URL, Headers, Opts) ->
    Req = fun ({n, l, [gproc_pool, {party_socket, _}, _, Pid]}, _) ->
                  party_socket:do(Pid, {get, URL, Headers, Opts}, timeout(Opts))
          end,

    case gproc_pool:claim(pool_name(endpoint(URL)), Req) of
        {true, Res} ->
            Res;
        false ->
            {error, max_concurrency}

    end.

post(URL, Headers, Body, Opts) ->
    ok.


%%
%% HELPERS
%%

endpoint(<<"http://", DomainPortPath/binary>>) ->
    case binary:split(DomainPortPath, <<":">>) of
        [Domain] ->
            {tcp, Domain, 80};
        [Domain, Rest] ->
            case binary:split(Rest, <<"/">>) of
                [Port] ->
                    {tcp, Domain, ?b2i(Port)};
                [Port, _Path] ->
                    {tcp, Domain, ?b2i(Port)}
            end
    end.




pool_name({_Protocol, _Domain, _Port} = Endpoint) ->
    {party_socket, Endpoint}.

timeout(Opts) -> proplists:get_value(timeout, Opts, 5000).
    
