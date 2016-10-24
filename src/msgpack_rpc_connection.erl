%%%-------------------------------------------------------------------
%%% @author UENISHI Kota <kuenishi@gmail.com>
%%% @copyright (C) 2012, UENISHI Kota
%%% @doc
%%%
%%% @end
%%% Created : 25 Jul 2012 by UENISHI Kota <kuenishi@gmail.com>
%%%-------------------------------------------------------------------
-module(msgpack_rpc_connection).

-behaviour(gen_server).

%% API
-export([start_link/1]).

-include_lib("eunit/include/eunit.hrl").
-include("msgpack_rpc.hrl").
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-ifdef(debug).
-define(LOG(X), io:format("{~p,~p}: ~p~n", [?MODULE,?LINE,X])).
string_format(Pattern, Values) -> lists:flatten(io_lib:format(Pattern, Values)).
-else.
-define(LOG(X), true).
-endif.

-record(state,
        {
          connection :: pid() | inet:socket(),
          transport  :: atom(),
          counter = 0 :: non_neg_integer(),
          session = [] :: [ {non_neg_integer(), none|{result,msgpack:msgpack_term()}|{waiting,term()}} ],
          buffer = <<>> :: binary(),
          module :: atom()
        }).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link([term()]) -> {ok, pid()} | ignore | {error, Error::term()}.
start_link(Argv) ->
    gen_server:start_link(?MODULE, Argv, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% TODO: add ability to pass verify_peer option. others?

-spec init([term()]) -> {ok, #state{}} | {ok, #state{}, non_neg_integer()} |
                        ignore | {stop, term()}.
init(Argv) ->
    Transport = proplists:get_value(transport, Argv, ranch_tcp),
    Opts = case Transport of
               ranch_tcp -> [binary,{packet,raw},{active,once}];
               ranch_ssl ->
                   CertFile = proplists:get_value(certfile, Argv),
                   KeyFile = proplists:get_value(keyfile, Argv),
                   Verify = proplists:get_value(verify, Argv, verify_none),
                   [binary, {packet, raw}, {active, once}, {verify, Verify},
                    {certfile, CertFile}, {keyfile, KeyFile}]
           end,
    IP   = proplists:get_value(ipaddr, Argv, localhost),
    Port = proplists:get_value(port,   Argv, 9199),
    Module = proplists:get_value(module, Argv, undefined),
    case Module of
      undefined ->
        error_logger:info_msg("~nInfo: No module is defined in msgpack_rpc_client:connect/4:Opts~n"),
        ok;
      _ -> ok
    end,
    %?debugVal(Opts),
    Timeout = proplists:get_value(timeout, Argv, infinity),
    {ok, Socket} = Transport:connect(IP, Port, Opts, Timeout),
    ok = Transport:controlling_process(Socket, self()),
    {ok, #state{connection=Socket, transport=Transport, module=Module}}.

-spec handle_call(term(), From::term(), #state{}) ->
                         {reply, Reply::term(), #state{}} |
                         {reply, Reply::term(), #state{}, non_neg_integer()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, non_neg_integer()} |
                         {stop, Reason::term(), Reply::term(), #state{}} |
                         {stop, Reason::term(), #state{}}.
handle_call({call_async, Method, Argv}, _From,
            State = #state{connection=Socket, transport=Transport, session=Sessions, counter=Count}) ->
    CallID = Count,
    Binary = msgpack:pack([?MP_TYPE_REQUEST, CallID, Method, Argv]),
    ok=Transport:send(Socket, Binary),
    ok=Transport:setopts(Socket, [{active,once}]),
    {reply, {ok, CallID}, State#state{counter=Count+1, session=[{CallID,none}|Sessions]}};

handle_call({join, CallID}, From, State = #state{session=Sessions0}) ->
    case lists:keytake(CallID, 1, Sessions0) of
        false -> {reply, {error, norequest}, State}; % unknown CallID
        
        {value, {CallID, none}, Sessions} -> % do receive
            {noreply, State#state{session=[{CallID,{waiting,From}}|Sessions]}};
        
        {value, {CallID, {result, Term}}, Sessions} ->
            {reply, Term, State#state{session=Sessions}};
        
        {value, {CallID, {waiting, From}}, _} ->
            {reply, {error, waiting}, State};
	    
        {value, {CallID, {waiting, From1}}, Sessions1} -> % overwrite
            {noreply, State#state{session=[{CallID, {waiting, From1}}|Sessions1]}};
        
        _ -> % unexpected error
            {noreply, State}
    end;

handle_call(close, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, badevent}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({notify, Method, Argv}, State = #state{connection=Socket, transport=Transport}) ->
    
    Binary = msgpack:pack([?MP_TYPE_NOTIFY, Method, Argv]),
    ok=Transport:send(Socket, Binary),
    {noreply, State};

handle_cast(_Msg, State)                                                                    ->
    {noreply, State}.

%% @doc
%% Handling all non call/cast messages
-spec handle_info(term(), #state{}) ->
                         {noreply, #state{}} | {stop, Reason::term(), #state{}}.

handle_info({TCP_or_SSL, Socket, Binary},
            State = #state{transport=Transport,session=Sessions0, buffer=Buf, module=Module})

  when TCP_or_SSL =:= tcp orelse TCP_or_SSL =:= ssl -> % this guard is quickhack; FIXME
    
    NewBuffer = <<Buf/binary, Binary/binary>>,
    ok=Transport:setopts(Socket, [{active,once}]),
    
    case msgpack:unpack_stream(NewBuffer) of
        {error, incomplete} ->
            {noreply, State#state{buffer=NewBuffer}};
        {error, {badarg, Reason}} ->
            {stop, {error, Reason}, State};
        {error, Reason} ->
            ?debugVal({error, Reason}),
            {noreply, State#state{buffer=NewBuffer}};
        {Term, Remain} ->
          case Term of
            %% Handle a response.
            [?MP_TYPE_RESPONSE, CallID, ResCode, Result] ->
              ?LOG(string_format("~n CallID: ~p ~n ResCode: ~p ~n Result: ~p", [CallID, ResCode, Result])),
              Retval = case ResCode of
                         null -> {ok, Result};
                         Error -> {error, msgpack_rpc_protocol:binary2known_error(Error)}
                       end,
              case lists:keytake(CallID, 1, Sessions0) of
                false -> {noreply, State};
                {value, {CallID, none}, Sessions} ->
                  {noreply, State#state{session = [{CallID, {result, Retval}} | Sessions],
                    buffer = Remain}};
                {value, {CallID, {waiting, From}}, Sessions} ->
                  gen_server:reply(From, Retval),
                  {noreply, State#state{session = Sessions, buffer = Remain}}
              end;
            %% Handle a notify message from the server.
            [?MP_TYPE_NOTIFY, Method, Argv] ->
              ?LOG(string_format("MFA: ~p ~p ~p", [Module, Method, Argv])),
              spawn_notify_handler(Module, Method, Argv),
              {noreply, State#state{buffer = Remain}}
          end
    end;

handle_info({tcp_closed, Socket}, State = #state{connection=Socket}) ->
    {stop, unexpected_close, State};
handle_info(_Info, State = #state{connection=Socket,transport=Transport}) ->
    ?debugVal(_Info),
    ok=Transport:setopts(Socket, [{active,once}]),
    {noreply, State}.

%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(term(), #state{}) -> ok. % void().
terminate(_Reason, _State = #state{connection=Socket, transport=Transport}) ->
    Transport:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
spawn_notify_handler(Module, M, A)                     ->
  spawn(
    fun()->
      Argv = lists:map(fun(X) -> binary_to_term(X) end, A),
      Method = binary_to_existing_atom(M, latin1),
      try
        if
          Module =:= undefined ->
            error_logger:error_msg("~nModule is undefined in MFA; call will fail.~n") ;
          true -> ok
        end,
        erlang:apply(Module, Method, Argv)
      catch
        Class:Throw ->
          error_logger:error_msg("~p ~p:~p", [?LINE, Class, Throw])
      end
    end).
