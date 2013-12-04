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
    %%Port = webserver:start(gen_tcp, [fun response_ok/5]),
    %%phttpc:connect(<<"http://localhost:", (?i2b(Port))/binary>>, 1),
    party:connect(<<"http://google.com:80">>, 1),

    error_logger:info_msg("~p~n",
                          [party:get(<<"http://google.com:80/hello">>,
                                     [], [])]),

    ok.



response_ok(Module, Socket, _, _, _) ->
    Module:send(
      Socket,
      "HTTP/1.1 200 OK\r\n"
      "Content-type: text/plain\r\nContent-length: 14\r\n\r\n"
      "Great success!").

    
