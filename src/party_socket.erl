-module(party_socket).
-behaviour(gen_server).
-include_lib("eunit/include/eunit.hrl").
-include("party.hrl").

%% API
-export([start_link/1, do/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([get_socket/1]).

-record(state, {endpoint,
                socket,
                caller,
                response,
                buffer,
                parser_state,
                timer
               }).

%%
%% API
%%

start_link(Endpoint) ->
    gen_server:start_link(?MODULE, [Endpoint], []).

do(Pid, Request, Timeout) ->
    gen_server:call(Pid, {do, Request}, Timeout).


get_socket(Pid) ->
    gen_server:call(Pid, get_socket).

%%
%% gen_server callbacks
%%

init([Endpoint]) ->
    {_Protocol, Domain, Port} = party:endpoint(Endpoint),

    gproc_pool:add_worker(
      party:pool_name(party:endpoint(Endpoint)), self()),

    %% TODO: ssl
    case gen_tcp:connect(?b2l(Domain), Port, [{active, false}, binary], 10000) of
        {ok, Socket} ->
            inet:setopts(Socket, [{active, once}]),

            gproc_pool:connect_worker(
              party:pool_name(party:endpoint(Endpoint)), self()),

            {ok, #state{endpoint = Endpoint,
                        socket = Socket,
                        parser_state = response,
                        buffer = <<"">>}};
        Error ->
            {stop, Error}
    end.


handle_call({do, Request}, From, #state{socket = undefined} = State) ->
    {_Protocol, Domain, Port} = party:endpoint(State#state.endpoint),
    case gen_tcp:connect(?b2l(Domain), Port, [{active, false}, binary], 10000) of
        {ok, Socket} ->
            ok = inet:setopts(Socket, [{active, once}]),
            case send_request(Request, Socket) of
                ok ->
                    Timer = start_timer(server_timeout(opts(Request))),
                    {noreply, State#state{caller = From,
                                          socket = Socket,
                                          timer = Timer}}
            end
    end;

handle_call({do, Request}, From, #state{socket = Socket} = State) ->
    case send_request(Request, Socket) of
        ok ->
            Timer = start_timer(server_timeout(opts(Request))),
            {noreply, State#state{caller = From,
                                 timer = Timer}}
    end;

handle_call(get_socket, _From, State) ->
    {reply, {ok, State#state.socket}, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, #state{socket = Socket, timer = Timer} = State) ->
    if Timer =:= undefined ->
            ok;
       true ->
            erlang:cancel_timer(Timer)
    end,
    ok = inet:setopts(Socket, [{active, once}]),

    NewBuffer = <<(State#state.buffer)/binary, Data/binary>>,
    case handle_response(Data, State#state{buffer = NewBuffer}) of
        {more, NewState} ->
            {noreply, NewState#state{timer = undefined}};

        {response, {_, Headers, _} = Response, NewState} ->
            gen_server:reply(NewState#state.caller, {ok, Response}),

            NewSocket = case lists:keyfind(<<"Connection">>, 1, Headers) of
                            {<<"Connection">>, <<"close">>} ->
                                ok = gen_tcp:close(Socket),
                                undefined;
                            {<<"Connection">>, <<"keep-alive">>} ->
                                Socket;
                            false ->
                                Socket
                        end,

            {noreply, NewState#state{caller = undefined,
                                     response = undefined,
                                     parser_state = response,
                                     socket = NewSocket,
                                     timer = undefined,
                                     buffer = <<"">>}}
    end;

handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {noreply, State#state{socket = undefined}};

handle_info({timeout, Timer, timeout}, #state{caller = From,
                                              socket = Socket,
                                              timer = Timer} = State) ->
    gen_server:reply(From, {error, timeout}),
    if Socket =/= undefined ->
            ok = gen_tcp:close(Socket);
       true ->
            ok
    end,
    {noreply, State#state{socket = undefined,
                          caller = undefined,
                          parser_state = response,
                          response = undefined,
                          buffer = <<"">>}}.





terminate(Reason, State) ->
    error_logger:info_msg("party_socket(~p) terminating: ~p~n",
                          [self(), Reason]),
    Pool = party:pool_name(party:endpoint(State#state.endpoint)),
    true = gproc_pool:disconnect_worker(Pool, self()),
    true = gproc_pool:remove_worker(Pool, self()),

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_request(Request, Socket) ->
    case gen_tcp:send(Socket, request(Request)) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.


request({get, URL, Headers, _Opts}) ->
    AllHeaders = [maybe_set_header(<<"Host">>, host(URL), Headers),
                  maybe_set_header(<<"Connection">>, connection(), Headers)
                  | Headers],

    [<<"GET ">>, path(URL), <<" HTTP/1.1\r\n">>,
     encode_headers(AllHeaders),
     <<"\r\n">>];

request({post, URL, Headers, Body, _Opts}) ->
    AllHeaders = [maybe_set_header(<<"Host">>, host(URL), Headers),
                  maybe_set_header(<<"Content-Length">>,
                                   ?i2b(iolist_size(Body)), Headers)
                  | Headers],
    [<<"POST ">>, path(URL), <<" HTTP/1.1\r\n">>,
     encode_headers(AllHeaders),
     <<"\r\n">>,
     Body].


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

host(<<"http://", DomainPortPath/binary>>) ->
    case binary:split(DomainPortPath, <<"/">>) of
        [D, _Path] -> D;
        [D] -> D
    end.

connection() ->
    <<"keep-alive">>.


path(<<"http://", DomainPortPath/binary>>) ->
    find_path(DomainPortPath).

find_path(<<"/", _/binary>> = Path) -> Path;
find_path(<<_, Rest/binary>>)       -> find_path(Rest);
find_path(<<"">>)                   -> <<"/">>.


maybe_set_header(Key, Value, L) ->
    case lists:keyfind(Key, 1, L) of
        {Key, _} ->
            [];
        false ->
            {Key, Value}
    end.


encode_headers([])           -> [];
encode_headers([[] | H])     -> encode_headers(H);
encode_headers([{K, V} | H]) -> [K, <<": ">>, V, <<"\r\n">>, encode_headers(H)].


opts({post, _, _, _, Opts}) -> Opts;
opts({get, _, _, Opts})      -> Opts.

server_timeout(Opts) -> proplists:get_value(server_timeout, Opts, 30000).


start_timer(Timeout) ->
    erlang:start_timer(Timeout, self(), timeout).


%%
%% TESTS
%%


path_test() ->
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com:80/hello/world">>)),
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com/hello/world">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com/">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com">>)).

host_test() ->
    ?assertEqual(<<"localhost:80">>, host(<<"http://localhost:80/foobar">>)),
    ?assertEqual(<<"localhost:80">>, host(<<"http://localhost:80">>)).
