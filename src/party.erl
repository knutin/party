%% @doc: Parallel http client
-module(party).
-include("party.hrl").
-export([connect/2, get/3, post/4, disconnect/1]).

-export([pool_name/1, endpoint/1, workers/0]).

connect(Endpoint, NumConnections) ->
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
    end.

disconnect(_Endpoint) ->
    lists:foreach(fun ({_, Pid, _, _}) ->
                          ok = supervisor:terminate_child(party_socket_sup, Pid)
                  end, supervisor:which_children(party_socket_sup)),
    ok.


get(URL, Headers, Opts) ->
    do({get, URL, Headers, Opts}, Opts).

post(URL, Headers, Body, Opts) ->
    do({post, URL, Headers, Body, Opts}, Opts).


do(Request, Opts) ->
    Req = fun (Pid, Lock, _ElapsedUs, _Misses) ->
                  party_socket:do(Pid, Request, Lock, call_timeout(Opts))
          end,
    Pool = pool_name(endpoint(url(Request))),
    case carpool:claim(Pool, Req, claim_timeout(Opts)) of
        {ok, Res} ->
            Res;
        {error, claim_timeout} ->
            {error, claim_timeout}
    end.

workers() ->
    lists:map(fun ({_, Pid, _, _}) ->
                      {ok, State} = party_socket:is_busy(Pid),
                      {Pid, State}
              end, supervisor:which_children(party_socket_sup)).



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

call_timeout(Opts) -> proplists:get_value(call_timeout, Opts, 5000).
claim_timeout(Opts) -> proplists:get_value(claim_timeout, Opts, 1000).
