-module(gaffer_ws_client).

-behaviour(gen_server).

%% API
-export([start_link/1]).
-export([connect/1]).
-export([send/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([key/0]).

-define(DISCONNECTED, 0).
-define(CONNECTING, 1).
-define(OPEN, 2).
-define(CLOSED, 3).

-define(SERVER, ?MODULE). 

-record(state, {readystate,key,host,port,path,sock,headers}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------
connect(Pid) ->
    gen_server:cast(Pid, connect).

send(Pid, Data) ->
   gen_server:cast(Pid, {send, Data}).

start_link(Url) ->
    gen_server:start_link(?MODULE, [Url], []).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Url]) ->
    {ok,{ws,[],Host,Port,Path,[]}} = http_uri:parse(Url),
    {ok, #state{readystate = ?DISCONNECTED, key = key(), host = Host, port = Port, path = Path}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(connect, State = #state{host = Host, port = Port, path = Path, key = Key}) ->
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {packet, 0},{active,true}]),
    Req = initial_request(Host, Port, Path, Key),
    inet:setopts(Sock, [{packet, http}]),
    ok = gen_tcp:send(Sock, Req),
    {noreply, State#state{sock = Sock}};
handle_cast({send, Data}, State = #state{sock = Sock}) ->
    io:format("Sending: ~p~n", [Data]),
    Result = gen_tcp:send(Sock, Data),
    io:format("result: ~p~n", [Result]),
    {noreply, State}.

handle_info({http,_,{http_response,{1,1},101,_}}, State = #state{readystate = ?DISCONNECTED}) ->
    {noreply, State#state{readystate = ?CONNECTING}};
handle_info({http,_,{http_header,_,Name,_,Value}}, State = #state{readystate = ?CONNECTING}) ->
    H = [{Name, Value} | State#state.headers],
    {noreply, State#state{headers=H}};
handle_info({http,_,http_eoh},State) ->
    {noreply, handshake(State)};
handle_info(Info, State) ->
    io:format("INFO = ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%----------------------------------------------------------------------------
%% Internal functions 
%%----------------------------------------------------------------------------
key() ->
    {A1,A2,A3} = now(),
    random:seed(A1,A2,A3),
    binary_to_list(base64:encode(<< <<(random:uniform(256))>> || _N <- lists:seq(1,16) >>)).

initial_request(Host,Port, Path, Key) ->
    "GET "++ Path ++" HTTP/1.1\r\n" ++
    "Host: " ++ Host ++ ":" ++ integer_to_list(Port) ++ "\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Upgrade: websocket\r\n" ++ 
    "Sec-WebSocket-Version: 13\r\n" ++
    "Sec-WebSocket-Key: " ++ Key ++ "\r\n\r\n".

handshake(State = #state{readystate = ?CONNECTING, sock = Sock, key = Key, headers = Headers}) ->
    "upgrade" = string:to_lower(proplists:get_value('Connection', Headers)),
    "websocket" = string:to_lower(proplists:get_value('Upgrade', Headers)),
    SecWebsocketAccept = proplists:get_value("Sec-Websocket-Accept", Headers),
    Expected = binary_to_list(base64:encode(crypto:sha(Key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))),
    case SecWebsocketAccept =:= Expected of 
        true -> 
            io:format("Connectionstate: Open, handshake complete!!"),
            inet:setopts(Sock, [{packet, raw}]),
            State#state{readystate = ?OPEN};
        _ -> 
            io:format("Connectionstate: Closed, invalid handshake"),
            State#state{readystate = ?CLOSED}
    end.
    
%% handshake_request(Url) ->
%%     {ok,{ws,[],Host,Port,Path,[]}} = http_uri:parse(Url).
    
%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
