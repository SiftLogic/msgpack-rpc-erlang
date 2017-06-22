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
-export( [ start_link/1 ] ).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-export([
  add/2,
  delete/2,
  notify_all_connections_on_host_port/4,
  notify_one_connection_on_host/4,
  notify_all_connections_on_host/3,
  notify_all_connections/2,
  get_connections/0,
  get_connections/1,
  stop/0,
  dump/0
  ]).

-import( lists, [ filter/2, map/2 ] ).

%%%===================================================================
%%% DEBUGGING UTILS: 
%%%===================================================================

debug( Fmt, Args ) -> error_logger:info_msg( Fmt, Args ).
debug( Msg ) -> error_logger:info_msg( Msg ).

dump() ->
  gen_server:call(?MODULE, dump).

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

add( Socket, Transport ) ->
  gen_server:cast( ?MODULE, { add, Socket, Transport } ).

%%--------------------------------------------------------------------
%% @doc
%% Delete a connection. Called by handler when client connection lost.
%% @end
%%--------------------------------------------------------------------
-spec delete(inet:socket(), module()) -> ok.

delete(Socket, Transport) ->
  gen_server:cast(?MODULE, {delete, Socket, Transport}).

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
    reply( gen_server:call( ?MODULE, { notify_all_ip_port, IPAddress, Port, Method, Argv } ) ).

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
%%  calling notify_one_connection_on_host( {{10,0,5,41},443,grant_access,[{10,0,5,206},{gpg,"Gpg_public_key"}]} )
%%--------------------------------------------------------------------
-spec notify_one_connection_on_host(term(), integer(), atom(), term()) -> ok.
notify_one_connection_on_host(IPAddress, Port, Method, Argv) ->
  reply( gen_server:call( ?MODULE, { notify_one_ip_port, IPAddress, Port, Method, Argv } ) ).

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
  reply( gen_server:call( ?MODULE, { notify_all, IPAddress, Method, Argv } ) ).

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
    reply( gen_server:call( ?MODULE, { notify_global, Method, Argv } ) ).

reply( ok ) -> ok;
reply( {error, no_active_connections} ) -> no_active_connections;
reply( Result ) -> Result.

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
-spec start_link( Listeners::[ term() ] ) -> { ok, Pid :: pid() } | ignore | { error, Reason :: term() }.

start_link( ListenerSpecs ) ->
    debug( "mgr:startlink: specs are ~p~n", [ ListenerSpecs ] ),
    gen_server:start_link( { local, ?MODULE }, ?MODULE, ListenerSpecs, [] ).


%%%===================================================================
%%%
%%% Initialization
%%%
%%%===================================================================

-define( NUM_ACCEPTORS, 5 ).

-record( state, { listeners::list(), connections :: list() } ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server.
%%
%% @spec init(Args) -> {ok, State}
%% @end
%%--------------------------------------------------------------------
-spec( init( Args :: term() ) -> { ok, State :: #state{} } ).

init( ListenerSpecs ) ->
    debug( "[A] Starting msgpack_rpc_connection_mgr, specs are ~p~n", [ ListenerSpecs ] ),
    process_flag( trap_exit, true ),

    self() ! { post_init, ListenerSpecs },

    { ok, #state{ listeners = [], connections = [] } }.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================


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

  case get_hosts_connections(IPAddress, AllOpenConnections) of
    [] ->
      {reply, {error, no_active_connections}, State#state{connections = AllOpenConnections}};

    HostConnections ->
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
      lists:map(fun({Socket, Transport,_ClientIp}) -> Transport:send(Socket, Binary) end, HostConnections),
      {reply, ok, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to all the connections in the system.
handle_call({notify_global, Method, Argv}, _From, #state{connections = Connections} = State) ->
  case cull_connections(Connections) of
    [] ->
      {reply, {error, no_active_connections}, State#state{connections = []}};

    AllOpenConnections ->
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
      lists:map(fun({Socket, Transport,_ClientIp}) -> Transport:send(Socket, Binary) end, AllOpenConnections),
      {reply, ok, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to a single connection on a client.
%% This call enforces that there is only one connection from a single host the the port on the server.

handle_call({notify_one_ip_port, IPAddress, _Port, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),

%  case get_connections_on_ip_and_port(IPAddress, Port, Connections) of
  case get_connections_on_ip_only(IPAddress, Connections) of
    [] ->
      {reply, {error, no_active_connections}, State#state{connections = AllOpenConnections}};

    [ { Socket, Transport, _ClientIp } ] ->
    %  {Socket, Transport, _ClientIp} = lists:last(FilteredConnections),
      Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),

      Result = Transport:send(Socket, Binary),
      {reply, Result, State#state{connections = AllOpenConnections}}
  end;

%% Send an aysnyochronous (one way) call back to all connections on a specifc port to a specific ip.
handle_call({notify_all_ip_port, IPAddress, Port, Method, Argv}, _From, #state{connections = Connections} = State) ->
  AllOpenConnections = cull_connections(Connections),
  Connections = get_connections_on_ip_and_port(IPAddress, Port, Connections),
  Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),

  lists:foreach(
    fun({Socket, Transport, _ClientIp }) ->
      _ = Transport:send(Socket, Binary)        %% Ignoring result since we don't use, and don't want crash
    end, Connections),

  {reply, ok, State#state{connections = AllOpenConnections}};

%--------------------
%
%   debug

handle_call( dump, _From, #state{connections = Connections} = State) ->
  { reply, Connections, State }.

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
    try ip_from_socket( Socket ) of
        { ok, { ClientIp, Port } } ->
            debug("New ~p connection from ~p:~b", [Transport, ClientIp, Port ] ),
            OpenConnections = cull_connections(Connections),
            { noreply, State#state{ connections = OpenConnections ++ [ { Socket, Transport, ClientIp } ] } }
    catch
        Type:Error ->
            debug( "Add connection from ~p failed: ~p:p", [ Socket, Type, Error ] ),
            { noreply, State }
    end;

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages:
%%  {delete, Socket, Transport} - deletes a connection from the list.
%%
%% @end
%%--------------------------------------------------------------------

%% Add a new connection to the list of open connections.
%%  TODO: This really should use ets vs list for scale

handle_cast({delete, Socket, Transport}, #state{connections = Connections} = State) ->
    debug("Lost ~p connection from ~s", [ Transport, ip_string( Socket, Transport ) ] ),

    F = fun ( { S, T, _C } ) -> { S, T } =/= { Socket, Transport } end,
    { noreply, State#state{ connections = lists:filter( F, Connections ) } }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages - there should be none.
%%
%% @spec handle_info(Info, State) -> {noreply, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) -> {noreply, NewState :: #state{}}).

handle_info( { post_init, ListenerSpecs }, State ) ->
    debug( "Starting listeners ~p~n", [ ListenerSpecs ] ) ,
    Listeners = map( fun start_listener/1, ListenerSpecs ),
    { noreply, State#state{ listeners = Listeners } };

handle_info(Info, State) ->
  debug( "Unknown info \"~p\"~n", [Info]),
  {noreply, State}.


start_listener( { Name, ApiModule, TransportHandler, Options } ) ->
    { ok, _ServerPid } = msgpack_rpc_server:start(
                                                Name,               %The name of the listener.
                                                ?NUM_ACCEPTORS,     %The number of acceptors.
                                                TransportHandler,   %The transport handler; tcp or ssl.
                                                ApiModule,          %The name of the module with the API.
                                                Options             %The list of ranch options.
                                            ),
    Name.



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
    Kept = filter(
            fun( { Socket, Transport, _ClientIp } ) ->
                case erlang:port_info( erlang_port( Socket, Transport ) ) of
                    undefined -> false;
                    _ -> true
                end       
            end, Connections ),

%   report what happened for debug

    case Connections -- Kept of
        [] -> Kept;
        Deleted ->
            debug( "Culled connections ~p", [ Deleted ] ),
            Kept
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single host/ipaddress
%% @end
%%--------------------------------------------------------------------
get_hosts_connections(IPAddress, AllOpenConnections) ->
  filter(
    fun( { Socket, Transport, _ClientIp } ) ->
      case inet:peername( erlang_port( Socket, Transport ) ) of
        { ok, { IPAddress, _ } } -> true;
        _ -> false
      end
    end, AllOpenConnections ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single host/ipaddress
%% @end
%%--------------------------------------------------------------------
get_connections_on_ip_only( IP, Connections ) ->
    F = fun( { Socket, Transport, _ClientIp } ) ->
            case inet:peername( erlang_port( Socket, Transport ) ) of
                { ok, { IP, _ } } -> true;
                _ -> false
            end
        end,
    filter( F, Connections ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns a list of connections on a single host/ipaddress/port
%% @end
%%--------------------------------------------------------------------
get_connections_on_ip_and_port( IP, Port, Connections ) ->
    F = fun( { Socket, Transport, _ClientIp } ) ->
            case inet:peername( erlang_port( Socket, Transport ) ) of
                { ok, { IP, Port } } -> true;
                _ -> false
            end
        end,
    filter( F, Connections ).

%%  TODO: wrong to match on tuple, use proper record

erlang_port( { sslsocket, { gen_tcp, SSLSocket, tls_connection, _ }, _ }, ranch_ssl ) ->
    SSLSocket;

erlang_port( Socket, ranch_tcp ) ->
    Socket.

erlang_port( { sslsocket, { gen_tcp, SSLSocket, tls_connection, _ }, _ } ) ->
    SSLSocket;

erlang_port( Socket ) ->
    Socket.



%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns the IP address for given socket, in string form
%% @end
%%--------------------------------------------------------------------

ip_from_socket( Socket ) -> inet:peername( erlang_port( Socket ) ).

ip_string( Socket, _Transport ) ->
    case ip_from_socket( Socket ) of
        { ok, { Address, Port } } ->
            inet:ntoa( Address );
        { ok, returned_non_ip_address } ->
            io_lib:format( "Bad socket ~p: returned_non_ip_address", [ Socket ] );
        { error, Reason } ->
            io_lib:format( "Bad socket ~p: ~p", [ Socket, Reason ] )
    end.
