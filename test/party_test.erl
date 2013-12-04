-module(party_test).
-include_lib("eunit/include/eunit.hrl").
-include("party.hrl").

integration_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [
      ?_test(simple()),
      ?_test(post()),
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
                 party:get(URL, [], [])).


post() ->
    Port = webserver:start(gen_tcp, [fun response_post/5]),
    ok = party:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    URL = <<"http://localhost:", (?i2b(Port))/binary, "/hello">>,
    Body = <<"name=knut">>,

    ?assertMatch({ok, {{200, <<"OK">>},
                       _, <<"hello knut">>}},
                 party:post(URL, [], Body, [])).


concurrency() ->
    ok = party:connect(<<"http://www.google.com:80">>, 2),

    URL = <<"http://www.google.com/">>,

    Parent = self(),
    spawn(fun () ->
                  Parent ! {self(), party:get(URL, [], [])}
          end),

    spawn(fun () ->
                  Parent ! {self(), party:get(URL, [], [])}
          end),

    receive M1 -> ?assertMatch({_, {ok, {{302, _}, _, _}}}, M1) end,
    receive M2 -> ?assertMatch({_, {ok, {{302, _}, _, _}}}, M2) end.


%%
%% HELPERS
%%

response_ok(Module, Socket, _, _, _) ->
    Module:send(
      Socket,
      "HTTP/1.1 200 OK\r\n"
      "Content-type: text/plain\r\nContent-length: 14\r\n\r\n"
      "Great success!").



response_post(Module, Socket, _Request, _RequestHeaders, RequestBody) ->
    <<"name=", Name/binary>> = RequestBody,
    ResponseBody = <<"hello ", Name/binary>>,


    Module:send(
      Socket,
      ["HTTP/1.1 200 OK\r\n",
       "Content-type: text/plain\r\n",
       "Content-length: ", ?i2l(byte_size(ResponseBody)), "\r\n",
       "\r\n",
       ResponseBody]).

