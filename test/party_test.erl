-module(party_test).
-include_lib("eunit/include/eunit.hrl").
-include("party.hrl").

integration_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [
      ?_test(simple())
     ]}.

setup() ->
    application:start(sasl),
    application:start(party).

teardown(_) ->
    application:stop(party).

simple() ->
    Port = webserver:start(gen_tcp, [fun response_ok/5]),
    party:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    %%party:connect(<<"http://localhost:8081">>, 1),
    URL = <<"http://localhost:", (?i2b(Port))/binary, "/hello">>,
    Host = <<"localhost:", (?i2b(Port))/binary>>,

    ?assertEqual({ok, {{200, <<"OK">>},
                       [{<<"Content-Length">>, <<"14">>},
                        {<<"Content-Type">>, <<"text/plain">>}]}},
                 party:get(URL, [{<<"Host">>, Host}], [])),

    ok.



response_ok(Module, Socket, _, _, _) ->
    Module:send(
      Socket,
      "HTTP/1.1 200 OK\r\n"
      "Content-type: text/plain\r\nContent-length: 14\r\n\r\n"
      "Great success!").

