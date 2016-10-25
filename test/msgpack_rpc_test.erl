-module(msgpack_rpc_test).

-include_lib("eunit/include/eunit.hrl").

-export([hello/1, add/2, tuple/1]).

hello(_Argv)->
    <<"hello">>.

tuple(Argv) ->
    {tuple, Argv, "tuple test", 123, <<"tuple_test">>}.

add(A, B)-> A+B.
    

start_stop_test()->
    ok = application:start(ranch),
    {ok, _} = msgpack_rpc_server:start(testlistener, 3, tcp, msgpack_rpc_test, [{port, 9199}]),

    %% Server tests with no connections.
    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_one_connection_on_host({127,0,0,1}, 9199, hello, [<<"hello">>])),
    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_all_connections_on_host({127,0,0,1}, hello, [<<"hello">>])),
    ?assertException(throw, {no_active_connections, _},
      msgpack_rpc_server:notify_all_connections(hello, [<<"hello">>])),

    %% Client tests.
    {ok, Pid} = msgpack_rpc_client:connect(tcp, "localhost", 9199, [{module, msgpack_rpc_test}]),

    Ref = make_ref(),
    {ok, Reply0} = msgpack_rpc_client:call(Pid, tuple, [Ref]),
    ?assertEqual({tuple, Ref, "tuple test", 123, <<"tuple_test">>}, Reply0),


    Reply = msgpack_rpc_client:call(Pid, hello, [<<"hello">>]),
    ?assertEqual({ok, <<"hello">>}, Reply),

    R = msgpack_rpc_client:call(Pid, add, [12, 23]),
    ?assertEqual({ok, 35}, R),

    ok = msgpack_rpc_client:notify(Pid, hello, [23]),

    %%   Server notifications tests with valid connections.
    [{_, ranch_tcp}] = msgpack_rpc_server:get_connections(),
    [{_, ranch_tcp}] = msgpack_rpc_server:get_connections({127,0,0,1}),
    ok = msgpack_rpc_server:notify_one_connection_on_host({127,0,0,1}, 9199, hello, [<<"hello">>]),
    timer:sleep(100),
    ok = msgpack_rpc_server:notify_all_connections_on_host_port({127,0,0,1}, 9199, hello, [<<"hello">>]),
    timer:sleep(100),
    ok = msgpack_rpc_server:notify_all_connections_on_host({127,0,0,1}, hello, [<<"hello">>]),
    timer:sleep(100),
    ok = msgpack_rpc_server:notify_all_connections(hello, [<<"hello">>]),

    %% Client tests.
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
