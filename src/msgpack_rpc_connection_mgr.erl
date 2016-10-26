%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. Sep 2016 6:42 AM
%%%-------------------------------------------------------------------
-module(msgpack_rpc_connection_mgr).

-behaviour(gen_server).

-include("msgpack_rpc.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-export([
  add/2,
  notify_all_connections_on_host_port/4,
  notify_one_connection_on_host/4,
  notify_all_connections_on_host/3,
  notify_all_connections/2,
  get_connections/0,
  get_connections/1,
  stop/0
  ]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% DEBUGGING UTILS
%% To turn on debugging, compile with the -Ddebug option to include a
%% macro named debug. i.e. erlc -Ddebug abspa_gen.erl
%% or add {d, debug} to erl_opts in rebar.config
%%%===================================================================
-ifdef(debug).
-define(LOG(X), io:format("{~p,~p}: ~p~n", [?MODULE,?LINE,X])).
string_format(Pattern, Values) -> lists:flatten(io_lib:format(Pattern, Values)).
-else.
-define(LOG(X), true).
-endif.

-record(state, {connections :: list()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Whenever a client connects to the server the socket and transport
%% are added to a list of active connections held in the loop data or state.
%% @end
%%--------------------------------------------------------------------
-spec add(inet:socket(), module()) -> ok.
add(Socket, Transport) ->
  gen_server:cast(?MODULE, {add,Socket, Transport}).

%%--------------------------------------------------------------------
%% @doc
%% Used to stop the connection manager.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
  gen_server:call(?MODULE, stop).

%%--------------------------------------------------------------------
%% @doc
%% To notify all connections on a host and port you must have the ip
%% address and the port.
%%
%% IPAddress should be of the form {127,0,0,1}
%%
%% @spec notify_all_connections_on_host_port(IPAddress, Port, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_all_connections_on_host_port(term(), term(), term(), term()) -> ok.
notify_all_connections_on_host_port(IPAddress, Port, Method, Argv) ->
  Result = gen_server:call(?MODULE, {notify_all_ip_port, IPAddress, Port, Method, Argv}),
  case Result of
    ok -> ok;
    {error, no_active_connections} -> no_active_connections;
    _ -> Result
  end.

%%--------------------------------------------------------------------
%% @doc
%% To notify a single connection on a host you must have the ip
%% address and the port.
%%
%% IPAddress should be of the form {127,0,0,1}
%%
%% @spec notify_one_connection_on_host(IPAddress, Port, Method, Arguments) -> ok.
%%
%% @end
%%--------------------------------------------------------------------
-spec notify_one_connection_on_host(term(), term(), term(), term()) -> ok.
notify_one_connection_on_host(IPAddress, Port, Method, Argv) ->
  Result = gen_server:call(?MODULE, {notify_one_ip_port, IPAddress, Port, Method, Argv}),
  case Result of
    ok -> ok;
    {error, no_active_connections} -> no_active_connections;
    _ -> Result
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
  Result = gen_server:call(?MODULE, {notify_all, IPAddress, Method, Argv}),
  case Result of
    ok -> ok;
    {error, no_active_connections} -> no_active_connections;
    _ -> Result
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
  Result = gen_server:call(?MODULE, {notify_global, Method, Argv}),
  case Result of
    ok -> ok;
    {error, no_active_connections} -> no_active_connections;
    _ -> Result
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
  gen_server:call(?MODULE, get_connections).

%%--------------------------------------------------------------------
%% @doc
%% Returns a list of {Socket, Transport} tuples for a single address.
%%
%% @spec get_connections(IPAddress) -> list().
%%
%% @end
%%--------------------------------------------------------------------
-spec get_connections(inet:ip_address()) -> list().
get_connections(IPAddress) ->
  gen_server:call(?MODULE, {get_connections, IPAddress}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the connection manager. This gen_server keeps a list of
%% open connections from clients and provides a few functions to send
%% asychronous messages to the client. The client to send a message to
%% is identified by ip address in erlang form {127,0,0,1}.
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server.
%%
%% @spec init(Args) -> {ok, State}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) -> {ok, State :: #state{}}).
init([]) -> {ok, #state{connections = []}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages get_connections and stop
%%
%%  {notify, IPAddress, Method, Argv} - sends an asynchronous message
%%    to the client with the IPAddress of the form {127,0,0,1}.
%%
%%  {notify_all, IPAddress, Method, Argv} - sends an asynchronous message
%%    to all the connection from a single IPAddress of the form {127,0,0,1}.
%%
%%  {notify_global, Method, Argv} - sends an asynchronous message
%%    to all connections in the system.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {noreply, NewState :: #state{}} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}}).

%% Get all open connections in the system.
handle_call(get_connections, _From, #state{connections = Connections} = State) ->
  OpenConnections = cull_connections(Connections),
  {reply, OpenConnections, State#state{connections = OpenConnections}};

%% Get all open connections to a single host.
handle_call({get_connections, IPAddress}, _From, #state{connections = Connections} = State) ->
  OpenConnections = cull_connections(Connections),
  HostConnections = get_hosts_connections(IPAddress, OpenConnections),
  {reply, HostConnections, State#state{connections = OpenConnections}};

%% Stop the msgpack_rpc_connection_mgr
handle_call(stop, _From, State) ->
  {stop, normal, ok, State};

%% Send an aysnyochronous (one way) call back to all the connections on a single client.
handle_call({notify_all, IPAddress, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),
  HostConnections = get_hosts_connections(IPAddress, AllOpenConnections),
  if
    length(HostConnections) > 0 ->
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
      lists:map(fun({Socket, Transport}) -> Transport:send(Socket, Binary) end, HostConnections),
      {reply, ok, State#state{connections = AllOpenConnections}};
    true ->
      {reply, {error, no_active_connections}, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to all the connections in the system.
handle_call({notify_global, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),
  if
    length(AllOpenConnections) > 0 ->
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
      lists:map(fun({Socket, Transport}) -> Transport:send(Socket, Binary) end, AllOpenConnections),
      {reply, ok, State#state{connections = AllOpenConnections}};
    true ->
      {reply, {error, no_active_connections}, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to a single connection on a client.
%% This call assumes that there is only one connection from a single host the the port on the server.
%% If there is more than one connection then this function picks the last one from the list.
handle_call({notify_one_ip_port, IPAddress, Port, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),
  FilteredConnections = get_connections_on_ip_and_port(IPAddress, Port, Connections),
  NumConnections = length(FilteredConnections),
  case NumConnections of
    0 ->
      {reply, {error, no_active_connections}, State#state{connections = AllOpenConnections}};
    _ ->
      {Socket, Transport} = lists:last(FilteredConnections),
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
      ok = Transport:send(Socket, Binary),
      {reply, ok, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to all connections on a specifc port to a specific ip.
handle_call({notify_all_ip_port, IPAddress, Port, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),
  Connections = get_connections_on_ip_and_port(IPAddress, Port, Connections),
  Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
  lists:foreach(
    fun({Socket, Transport}) ->
      ok = Transport:send(Socket, Binary)
    end, Connections),
  {reply, ok, State#state{connections = AllOpenConnections}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages:
%%  {add, Socket, Transport} - adds a new connections to the list.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}}).

%% Add a new connection to the list of open connections.
handle_cast({add, Socket, Transport}, #state{connections = Connections} = State) ->
  ?LOG(string_format("Adding connection: ~p ~p", [Socket, Transport])),
  OpenConnections = cull_connections(Connections),
  {noreply, State#state{connections = OpenConnections ++ [{Socket, Transport}]}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages - there should be none.
%%
%% @spec handle_info(Info, State) -> {noreply, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}}).
handle_info(Info, State) ->
  io:format("Unknown info \"~p\"~n", [Info]),
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Looks at the entire list of connections and removes those that are
%% no longer active.
%% @end
%%--------------------------------------------------------------------
cull_connections(Connections) ->
  lists:filter(
    fun({Socket, Transport}) ->
      Port = case Transport of
        ranch_ssl -> {sslsocket, {gen_tcp, SSLSocket,tls_connection, _}, _} = Socket,
          SSLSocket;
        ranch_tcp -> Socket
      end,
      case erlang:port_info(Port) of
        undefined -> false;
        _ -> true
      end
    end, Connections).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single host/ipaddress
%% @end
%%--------------------------------------------------------------------
get_hosts_connections(IPAddress, AllOpenConnections) ->
  lists:filter(
    fun({Socket, Transport}) ->
      Port = case Transport of
        ranch_ssl -> {sslsocket, {gen_tcp, SSLSocket,tls_connection, _}, _} = Socket,
          SSLSocket;
        ranch_tcp -> Socket
      end,
      {ok, {Address, _}} = inet:peername(Port),
      case IPAddress of
        Address -> true;
        _ -> false
      end
    end, AllOpenConnections).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single host/ipaddress/port
%% @end
%%--------------------------------------------------------------------
get_connections_on_ip_and_port(IPAddress, Port, Connections) ->
  get_connections_on_port(
    get_hosts_connections(IPAddress,
      cull_connections(Connections)), Port).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single port
%% @end
%%--------------------------------------------------------------------
get_connections_on_port(Connections, Port) ->
  lists:filter(
    fun({Socket, Transport}) ->
      S = case Transport of
            ranch_ssl -> {sslsocket, {gen_tcp, SSLSocket,tls_connection, _}, _} = Socket,
              SSLSocket;
            ranch_tcp -> Socket
          end,
      case inet:port(S) of
        {ok, Port} -> true;
        _ -> false
      end
    end, Connections).
