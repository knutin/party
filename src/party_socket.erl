-module(party_socket).
-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("party.hrl").

%% API
-export([start_link/1, do/4, is_busy/1]).

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
                timer,
                lock
               }).

%%
%% API
%%

start_link(Endpoint) ->
    gen_server:start_link(?MODULE, [Endpoint], []).

do(Pid, Request, Lock, Timeout) ->
    try
        gen_server:call(Pid, {do, Request, Lock}, Timeout)
    catch
        exit:{timeout, _} ->
            {error, timeout}
    end.


is_busy(Pid) ->
    gen_server:call(Pid, is_busy).

get_socket(Pid) ->
    gen_server:call(Pid, get_socket).

%%
%% gen_server callbacks
%%

init([Endpoint]) ->
    ok = carpool:connect(party:pool_name(party:endpoint(Endpoint))),
    {ok, #state{endpoint = Endpoint,
                socket = undefined,
                parser_state = response,
                buffer = <<"">>,
                lock = undefined}}.


handle_call({do, Request, Lock}, From, #state{caller = undefined} = State) ->
    case maybe_connect(State#state.endpoint, State#state.socket) of
        {ok, Socket} ->
            case send_request(Request, Socket) of
                ok ->
                    Timer = start_timer(server_timeout(opts(Request))),
                    {noreply, State#state{caller = From,
                                          timer = Timer,
                                          socket = Socket,
                                          lock = Lock}};
                {error, einval} ->
                    {reply, {error, timeout}, State};
                {error, closed} ->
                    {reply, {error, timeout}, State}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({do, _Request, _Lock}, _From, State) ->
    {reply, {error, busy}, State};

handle_call(get_socket, _From, State) ->
    {reply, {ok, State#state.socket}, State};

handle_call(is_busy, _From, State) ->
    {reply, {ok, State#state.caller =/= undefined}, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, _Socket, _Data}, #state{socket = undefined} = State) ->
    error_logger:info_msg("party got tcp response too late~n"),
    {noreply, State};

handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, once}]),

    NewBuffer = <<(State#state.buffer)/binary, Data/binary>>,
    case handle_response(Data, State#state{buffer = NewBuffer}) of
        {more, NewState} ->
            {noreply, NewState};

        {response, {_, Headers, _} = Response, NewState} ->
            ok = carpool:release(State#state.lock),
            gen_server:reply(NewState#state.caller, {ok, Response}),
            erlang:cancel_timer(State#state.timer),

            NewSocket = case lists:keyfind(<<"Connection">>, 1, Headers) of
                            {<<"Connection">>, <<"close">>} ->
                                ok = gen_tcp:close(Socket),
                                undefined;
                            {<<"Connection">>, _} ->
                                %% Keep alive is default for HTTP 1.1
                                Socket;
                            false ->
                                Socket
                        end,

            {noreply, NewState#state{caller = undefined,
                                     response = undefined,
                                     parser_state = response,
                                     socket = NewSocket,
                                     timer = undefined,
                                     buffer = <<"">>,
                                     lock = undefined}}
    end;

handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    EmptyState = State#state{caller = undefined,
                             response = undefined,
                             parser_state = response,
                             socket = undefined,
                             timer = undefined,
                             buffer = <<"">>,
                             lock = undefined},
    case State#state.caller of
        undefined ->
            ok;
        From ->
            gen_server:reply(From, {error, timeout})
    end,

    case State#state.lock =/= undefined of
        true ->
            ok = carpool:release(State#state.lock);
        false ->
            ok
    end,

    case State#state.timer =/= undefined of
        true ->
            erlang:cancel_timer(State#state.timer);
        false ->
            ok
    end,

    {noreply, EmptyState};

handle_info({timeout, Timer, timeout}, #state{caller = From,
                                              socket = Socket,
                                              timer = Timer} = State) ->
    ok = carpool:release(State#state.lock),
    gen_server:reply(From, {error, timeout}),
    case Socket =/= undefined of
        true ->
            ok = gen_tcp:close(Socket);
        false ->
            ok
    end,
    {noreply, State#state{socket = undefined,
                          caller = undefined,
                          parser_state = response,
                          response = undefined,
                          buffer = <<"">>}};

handle_info({timeout, Timer, timeout}, #state{timer = undefined} = State) ->
    error_logger:info_msg("got timeout from ~p, but don't have timer~n",
                          [Timer]),
    {noreply, State};

handle_info({timeout, OtherTimer, timeout}, #state{timer = Timer} = State) ->
    error_logger:info_msg("got timeout from ~p, but my timer is ~p~n",
                          [OtherTimer, Timer]),
    {noreply, State}.




terminate(Reason, State) ->
    error_logger:info_msg("party_socket(~p) terminating:~n~p~n",
                          [self(), Reason]),
    Pool = party:pool_name(party:endpoint(State#state.endpoint)),
    ok = carpool:disconnect(Pool),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maybe_connect(Endpoint, undefined) -> connect(Endpoint);
maybe_connect(_Endpoint, Socket) -> {ok, Socket}.

connect(Endpoint) ->
    {_Protocol, Domain, Port} = party:endpoint(Endpoint),
    case gen_tcp:connect(?b2l(Domain), Port,
                         [{active, false}, binary],
                         10000) of
        {ok, Socket} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {ok, Socket};
        {error, Reason} ->
            {error, Reason}
    end.




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

-ifdef(TEST).

path_test() ->
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com:80/hello/world">>)),
    ?assertEqual(<<"/hello/world">>, path(<<"http://foobar.com/hello/world">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com/">>)),
    ?assertEqual(<<"/">>, path(<<"http://foobar.com">>)).

host_test() ->
    ?assertEqual(<<"localhost:80">>, host(<<"http://localhost:80/foobar">>)),
    ?assertEqual(<<"localhost:80">>, host(<<"http://localhost:80">>)).

-endif.
