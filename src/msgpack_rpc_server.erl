%%% @author UENISHI Kota <kota@basho.com>
%%% @copyright (C) 2012, UENISHI Kota
%%% @doc
%%%
%%% @end
%%% Created : 29 Sep 2012 by UENISHI Kota <kota@basho.com>

-module(msgpack_rpc_server).

-export([start/4, start/5, stop/1]).
-export([notify_one_connection_on_host/4]).
-export([notify_all_connections_on_host_port/4]).
-export([notify_all_connections/2]).
-export([notify_all_connections_on_host/3]).
-export([get_connections/0, get_connections/1]).

-spec start(atom(), tcp|ssl, atom(), proplists:proplists())
           -> {ok, pid()} | {error, term()}.
start(Name, Transport, Module, Opts)->
    start(Name, 4, Transport, Module, Opts).

start(Name, NumProc, ssl, Module, Opts)->
%%
%%  disable: handled by controller's sup tree now. ugh
%%  msgpack_rpc_connection_mgr:start_link(),
    ranch:start_listener(Name, NumProc, ranch_ssl, Opts,
                         msgpack_rpc_protocol, [{module, Module}]);
start(Name, NumProc, tcp, Module, Opts)->
%%
%%  disable: handled by controller's sup tree now. ugh
%%  msgpack_rpc_connection_mgr:start_link(),
    ranch:start_listener(Name, NumProc, ranch_tcp, Opts,
                         msgpack_rpc_protocol, [{module, Module}]).

-spec stop(atom()) -> ok.
stop(Name) ->
%%  disable: handled by controller's sup tree now. ugh
%   msgpack_rpc_connection_mgr:stop(),
    ranch:stop_listener(Name).

%%--------------------------------------------------------------------
%% @doc
%% Notify all connection on an ip/port.
%%
%% IPAddress should be of the form {127,0,0,1}
%%
%% @spec notify_all_connections_on_host_port(IPAddress, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_all_connections_on_host_port(term(), term(), term(), term()) -> ok.
notify_all_connections_on_host_port(IPAddress, Port, Method, Argv) ->

  BinArgv = lists:map(fun(X) -> term_to_binary(X) end, Argv),

  Result = msgpack_rpc_connection_mgr:notify_all_connections_on_host_port(IPAddress, Port, Method, BinArgv),
  if
    Result =:= no_active_connections ->
      throw({no_active_connections, "There are no active connections to this host."});
    true ->
      Result
  end.

%%--------------------------------------------------------------------
%% @doc
%% While there may be more than one connection to the server from
%% the same ip address we may only want to send a notification to one.
%% If there is more than one connection, there is no guarantee which
%% one will get notified.
%%
%% IPAddress should be of the form {127,0,0,1}
%%
%% @spec notify_one_connection_on_host(IPAddress, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_one_connection_on_host(term(), term(), term(), term()) -> ok.
notify_one_connection_on_host(IPAddress, Port, Method, Argv) ->

  BinArgv = lists:map(fun(X) -> term_to_binary(X) end, Argv),

  Result = msgpack_rpc_connection_mgr:notify_one_connection_on_host(IPAddress, Port, Method, BinArgv),
  if
    Result =:= no_active_connections ->
      throw({no_active_connections, "There are no active connections to this host."});
    true ->
      Result
  end.

%%--------------------------------------------------------------------
%% @doc
%% Send a notification to all connections on a server. That is,
%% if there are multiple connections to the server from the same
%% IP address then all of them will get notified.
%%
%% IPAddress should be of the form {127,0,0,1}
%%
%% @spec notify_all_connections_on_host(IPAddress, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_all_connections_on_host(term(), term(), term()) -> ok.
notify_all_connections_on_host(IPAddress, Method, Argv) ->

  BinArgv = lists:map(fun(X) -> term_to_binary(X) end, Argv),

  Result = msgpack_rpc_connection_mgr:notify_all_connections_on_host(IPAddress, Method, BinArgv),
  if
    Result =:= no_active_connections ->
      throw({no_active_connections, "There are no active connections to this host."});
    true ->
      Result
  end.

%%--------------------------------------------------------------------
%% @doc
%% Send a notification to all open connections from all IP
%% addresses in the system.
%%
%% @spec notify_all_connections(IPAddress, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_all_connections(term(), term()) -> ok.
notify_all_connections(Method, Argv) ->

  BinArgv = lists:map(fun(X) -> term_to_binary(X) end, Argv),

  Result = msgpack_rpc_connection_mgr:notify_all_connections(Method, BinArgv),
  if
    Result =:= no_active_connections ->
      throw({no_active_connections, "There are no active connections in the system."});
    true ->
      Result
  end.

%%--------------------------------------------------------------------
%% @doc
%% Returns a list of {Socket, Transport} tuples.
%%
%% @spec get_connections() -> list().
%%
%% @end
%%--------------------------------------------------------------------
-spec get_connections() -> list().
get_connections() ->
  msgpack_rpc_connection_mgr:get_connections().

%%--------------------------------------------------------------------
%% @doc
%% Returns a list of {Socket, Transport} tuples for a single address.
%%
%% @spec get_connections(IPAddress) -> list().
%%
%% @end
%%--------------------------------------------------------------------
-spec get_connections(inet:ip4_address()) -> list().
get_connections(IPAddress) ->
  msgpack_rpc_connection_mgr:get_connections(IPAddress).
