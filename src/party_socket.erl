-module(party_socket).
-behaviour(gen_server).
-include_lib("eunit/include/eunit.hrl").
-include("party.hrl").

%% API
-export([start_link/1, do/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {endpoint, socket, caller, response, buffer, parser_state}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Endpoint) ->
    gen_server:start_link(?MODULE, [Endpoint], []).

do(Pid, Request, Timeout) ->
    gen_server:call(Pid, {do, Request}, Timeout).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Endpoint]) ->
    {_Protocol, Domain, Port} = party:endpoint(Endpoint),

    gproc_pool:add_worker(
      party:pool_name(party:endpoint(Endpoint)), self()),

    %% TODO: ssl
    error_logger:info_msg("connecting to: ~p:~p", [Domain, Port]),
    case gen_tcp:connect(?b2l(Domain), Port, [{active, false}, binary], 1000) of
        {ok, Socket} ->
            inet:setopts(Socket, [{active, once}]),

            error_logger:info_msg("socket connected, endpoint: ~p~n",
                                  [party:endpoint(Endpoint)]),
            gproc_pool:connect_worker(
              party:pool_name(party:endpoint(Endpoint)), self()),

            {ok, #state{endpoint = Endpoint,
                        socket = Socket,
                        parser_state = response,
                        buffer = <<"">>}};
        Error ->
            {stop, Error}
    end.


handle_call({do, Request}, From, State) ->
    case send_request(Request, State) of
        ok ->
            {noreply, State#state{caller = From}}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, #state{socket = Socket,
                                        response = undefined} = State) ->
    error_logger:info_msg("building new response, buf: ~p~n", [Data]),
    ok = inet:setopts(Socket, [{active, once}]),

    NewBuffer = <<(State#state.buffer)/binary, Data/binary>>,
    case handle_response(Data, State#state{buffer = NewBuffer}) of
        {more, NewState} ->
            {noreply, NewState};
        {response, Response, NewState} ->
            gen_server:reply(NewState#state.caller, {ok, Response}),
            {noreply, NewState#state{caller = undefined,
                                     response = undefined,
                                     parser_state = response,
                                     buffer = <<"">>}}
    end;

handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    %% reconnect?
    {noreply, State}.




terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_request({get, URL, Headers, Opts}, #state{socket = S} = State) ->
    AllHeaders = Headers,
    Request = [<<"GET ">>, path(URL), <<" HTTP/1.1\r\n">>,
               encode_headers(AllHeaders),
              <<"\r\n">>],

    case gen_tcp:send(S, Request) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

handle_response(Buffer, State) ->
    case State#state.parser_state of
        response ->
            case erlang:decode_packet(http_bin, Buffer, []) of
                {ok, {http_response, {1, 1}, StatusCode, Reason}, NewBuffer} ->
                    Response = {{StatusCode, Reason}, [], <<"">>},
                    handle_response(NewBuffer, State#state{response = Response,
                                                           buffer = NewBuffer,
                                                           parser_state = headers});
                {more, _} ->
                    {more, State#state{buffer = Buffer}}
            end;

        headers ->
            case erlang:decode_packet(httph_bin, Buffer, []) of
                {ok, {http_header, _, Name, _, Value}, NewBuffer} ->
                    BinName = if is_atom(Name) ->
                                      atom_to_binary(Name, utf8);
                                 true ->
                                      Name
                              end,
                    {Status, Headers, <<"">>} = State#state.response,
                    NewResponse = {Status, [{BinName, Value} | Headers], <<"">>},
                    handle_response(NewBuffer, State#state{response = NewResponse,
                                                           buffer = NewBuffer});
                {ok, http_eoh, NewBuffer} ->
                    handle_response(NewBuffer, State#state{parser_state = body});

                {more, _} ->
                    {more, State#state{buffer = Buffer}}
            end;

        body ->
            {Status, Headers, PartialBody} = State#state.response,
            NewBuffer = <<PartialBody/binary, Buffer/binary>>,

            {<<"Content-Length">>, ContentLengthBin} =
                lists:keyfind(<<"Content-Length">>, 1, Headers),
            ContentLength = ?b2i(ContentLengthBin),

            case byte_size(NewBuffer) == ContentLength of
                true ->
                    {response, {Status, Headers, NewBuffer}, State};
                false ->
                    Response = {Status, Headers, NewBuffer},
                    {more, State#state{response = Response,
                                       buffer = <<"">>}}
            end
    end.


%%
%% HELPERS
%%

path(<<"http://", DomainPortPath/binary>>) ->
    find_path(DomainPortPath).

find_path(<<"/", _/binary>> = Path) -> Path;
find_path(<<_, Rest/binary>>)       -> find_path(Rest);
find_path(<<"">>)                   -> <<"/">>.



encode_headers([])           -> [];
encode_headers([[] | H])     -> encode_headers(H);
encode_headers([{K, V} | H]) -> [K, <<": ">>, V, <<"\r\n">>, encode_headers(H)].


%%
%% TESTS
%%


path_test() ->
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com:80/hello/world">>)),
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com/hello/world">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com/">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com">>)).
