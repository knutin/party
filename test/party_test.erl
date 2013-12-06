-module(party_test).
-include_lib("eunit/include/eunit.hrl").
-include("party.hrl").

integration_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [
      ?_test(simple()),
      ?_test(post()),
      ?_test(large_response()),
      ?_test(reconnect()),
      ?_test(timeout()),
      ?_test(concurrency())
     ]}.

setup() ->
    application:start(sasl),
    application:start(party).

teardown(_) ->
    application:stop(party).

simple() ->
    Port = webserver:start(gen_tcp, [fun response_ok/5]),
    ok = party:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    URL = <<"http://localhost:", (?i2b(Port))/binary, "/hello">>,

    ?assertEqual({ok, {{200, <<"OK">>},
                       [{<<"Content-Length">>, <<"14">>},
                        {<<"Content-Type">>, <<"text/plain">>}],
                      <<"Great success!">>}},
                 party:get(URL, [], [])),

    ok = party:disconnect(ignored).


post() ->
    Port = webserver:start(gen_tcp, [fun response_post/5]),
    ok = party:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    URL = <<"http://localhost:", (?i2b(Port))/binary, "/hello">>,
    Body = <<"name=knut">>,

    ?assertMatch({ok, {{200, <<"OK">>},
                       _, <<"hello knut">>}},
                 party:post(URL, [], Body, [])),
    ok = party:disconnect(<<"http://localhost:", (?i2b(Port))/binary>>).

large_response() ->
    Port = webserver:start(gen_tcp, [fun response_large/5, fun response_large/5]),
    ok = party:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    URL = <<"http://localhost:", (?i2b(Port))/binary, "/hello">>,

    ExpectedBody = binary:copy(<<"x">>, 10240),
    ?assertMatch({ok, {{200, <<"OK">>},
                       _, ExpectedBody}},
                 party:post(URL, [], <<"">>, [])),
    ?assertMatch({ok, {{200, <<"OK">>},
                       _, ExpectedBody}},
                 party:post(URL, [], <<"">>, [])),
    ok = party:disconnect(ignored).


reconnect() ->
    URL = <<"http://dynamodb.us-east-1.amazonaws.com/">>,
    ok = party:connect(URL, 2),
    [{_, Pid, _, _}, _] = supervisor:which_children(party_socket_sup),

    {ok, Socket1} = party_socket:get_socket(Pid),

    KeepAlive = [{<<"Connection">>, <<"keep-alive">>}],
    ?assertMatch({ok, {{400, _}, _, _}}, party:post(URL, KeepAlive, [], [])),
    ?assertEqual({ok, Socket1}, party_socket:get_socket(Pid)),

    ?assertMatch({ok, {{400, _}, _, _}}, party:post(URL, KeepAlive, [], [])),
    ?assertEqual({ok, Socket1}, party_socket:get_socket(Pid)),

    Close = [{<<"Connection">>, <<"close">>}],
    ?assertMatch({ok, {{400, _}, _, _}}, party:post(URL, Close, [], [])),
    ?assertEqual({ok, undefined}, party_socket:get_socket(Pid)),

    ?assertMatch({ok, {{400, _}, _, _}}, party:post(URL, Close, [], [])),
    {ok, Socket2} = party_socket:get_socket(Pid),
    ?assertNotEqual(Socket1, Socket2),
    ?assertMatch({ok, {{400, _}, _, _}}, party:post(URL, Close, [], [])),
    ?assertEqual({ok, Socket2}, party_socket:get_socket(Pid)).




timeout() ->
    URL = <<"http://dynamodb.us-east-1.amazonaws.com/">>,

    ?assertEqual({error, timeout}, party:post(URL, [], [],
                                              [{server_timeout, 0},
                                               {call_timeout, 1000}])).



concurrency() ->
    URL = <<"http://dynamodb.us-east-1.amazonaws.com/">>,
    Parent = self(),
    spawn(fun () ->
                  Parent ! {self(), party:post(URL, [], [], [])}
          end),

    spawn(fun () ->
                  Parent ! {self(), party:post(URL, [], [], [])}
          end),

    receive M1 -> ?assertMatch({_, {ok, {{400, _}, _, _}}}, M1) end,
    receive M2 -> ?assertMatch({_, {ok, {{400, _}, _, _}}}, M2) end.



%%
%% HELPERS
%%

response_ok(Module, Socket, _, _, _) ->
    Module:send(
      Socket,
      "HTTP/1.1 200 OK\r\n"
      "Content-type: text/plain\r\nContent-length: 14\r\n\r\n"
      "Great success!").



response_post(Module, Socket, Request, _RequestHeaders, RequestBody) ->
    <<"name=", Name/binary>> = RequestBody,
    ResponseBody = <<"hello ", Name/binary>>,

    ?assertEqual({http_request, 'POST', {abs_path, "/hello"}, {1, 1}},
                  Request),

    Module:send(
      Socket,
      ["HTTP/1.1 200 OK\r\n",
       "Content-type: text/plain\r\n",
       "Content-length: ", ?i2l(byte_size(ResponseBody)), "\r\n",
       "\r\n",
       ResponseBody]).


response_large(Module, Socket, _, _, _) ->
    ResponseBody = binary:copy(<<"x">>, 10240),

    Module:send(
      Socket,
      ["HTTP/1.1 200 OK\r\n",
       "Content-type: text/plain\r\n",
       "Content-length: ", ?i2l(byte_size(ResponseBody)), "\r\n",
       "\r\n",
       ResponseBody]).

response_close(Module, Socket, _, Headers, _) ->
    error_logger:info_msg("~p~n", [Headers]),
    ?assertEqual("keep-alive", proplists:get_value("Connection", Headers)),
    Module:send(
      Socket,
      ["HTTP/1.1 200 OK\r\n",
       "Content-type: text/plain\r\n",
       "Content-length: 14\r\n",
       "Connection: close\r\n",
       "\r\n"
       "Great success!"]).
