-module(msgpack_rpc_test).

-include_lib("eunit/include/eunit.hrl").

-export([hello/1, add/2]).

hello(_Argv)->
    <<"hello">>.

add(A, B)-> A+B.
    

start_stop_test()->
    ok = application:start(ranch),
    {ok, _} = msgpack_rpc_server:start(testlistener, 3, tcp, msgpack_rpc_test, [{port, 9199}]),

    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_one_connection_on_host({127,0,0,1}, hello, [<<"hello">>])),
    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_all_connections_on_host({127,0,0,1}, hello, [<<"hello">>])),
    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_all_connections(hello, [<<"hello">>])),

    {ok, Pid} = msgpack_rpc_client:connect(tcp, "localhost", 9199, [{module, msgpack_rpc_test}]),
    Reply = msgpack_rpc_client:call(Pid, hello, [<<"hello">>]),
    ?assertEqual({ok, <<"hello">>}, Reply),

    R = msgpack_rpc_client:call(Pid, add, [12, 23]),
    ?assertEqual({ok, 35}, R),

    ok = msgpack_rpc_client:notify(Pid, hello, [23]),

  %% Test server notifications.
    [{_, ranch_tcp}] = msgpack_rpc_server:get_connections(),
    [{_, ranch_tcp}] = msgpack_rpc_server:get_connections({127,0,0,1}),
    ok = msgpack_rpc_server:notify_one_connection_on_host({127,0,0,1}, hello, [<<"hello">>]),
    timer:sleep(100),
    ok = msgpack_rpc_server:notify_all_connections_on_host({127,0,0,1}, hello, [<<"hello">>]),
    timer:sleep(100),
    ok = msgpack_rpc_server:notify_all_connections(hello, [<<"hello">>]),

    {ok, CallID0} = msgpack_rpc_client:call_async(Pid, add, [-23, 23]),
    ?assertEqual({ok, 0}, msgpack_rpc_client:join(Pid, CallID0)),

    {ok, CallID1} = msgpack_rpc_client:call_async(Pid, add, [-23, 46]),
    ?assertEqual({ok, 23}, msgpack_rpc_client:join(Pid, CallID1)),

    % wrong arity, wrong function
    {error, undef} = msgpack_rpc_client:call(Pid, add, [-23]),
    {error, undef} = msgpack_rpc_client:call(Pid, imaginary, []),

    ok = msgpack_rpc_client:close(Pid),

    ok = msgpack_rpc_server:stop(testlistener),
    ok = application:stop(ranch).
