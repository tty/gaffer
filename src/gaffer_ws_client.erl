-module(gaffer_ws_client).

-behaviour(gen_server).

%% API
-export([connect/1]).
-export([send_text/2, send_binary/2]).
-export([receive_loop/6]).
-export([ping/1]).
-export([start_link/2]).
-export([get_readystate/1]).
-export([decode_len/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(DISCONNECTED, 0).
-define(CONNECTING, 1).
-define(OPEN, 2).
-define(CLOSED, 3).

-define(OP_CONT, 0).
-define(OP_TEXT, 1).
-define(OP_BINARY, 2).
-define(OP_CLOSE, 8).
-define(OP_PING, 9).
-define(OP_PONG, 10).

-define(SERVER, ?MODULE).

-record(state, {readystate,
                handler,
                handlerstate,
                key,
                transport,
                host, port, path,
                sock,
                headers}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

connect(Pid) ->
    ok = gen_server:call(Pid, connect),
    wait_for_connect(Pid).

get_readystate(Pid) ->
    gen_server:call(Pid, get_readystate).

send_text(Pid, Text) ->
    gen_server:cast(Pid, {send, ?OP_TEXT, Text}).

send_binary(Pid, Data) ->
    gen_server:cast(Pid, {send, ?OP_BINARY, Data}).

ping(Pid) ->
    gen_server:cast(Pid, {send, ?OP_PING, <<>>}).

start_link(Handler, Url) ->
    gen_server:start_link(?MODULE, [Handler, Url], []).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Handler, Url]) ->
    {ok,{Protocol,[],Host,Port,Path,[]}} = http_uri:parse(Url, [{scheme_defaults, [{ws,80},{wss,443}]}]),
    Transport = case Protocol of
                    wss -> ssl;
                    ws -> gen_tcp
                end,
    {ok, HandlerState} = Handler:init([]),
    {ok, #state{readystate = ?DISCONNECTED,
                handler = Handler, handlerstate = HandlerState,
                key = key(),
                transport = Transport, host = Host, port = Port, path = Path}}.

handle_call(connect, _From, State = #state{transport = Transport, host = Host, port = Port,
                                    path = Path, key = Key}) ->
    Opts = case Transport of
               ssl -> [{verify, verify_none}];
               _ -> []
           end,
    {ok, Sock} = Transport:connect(Host, Port, Opts ++ [binary, {packet, 0},
                                              {active,true}]),
    Req = initial_request(Host, Port, Path, Key),
    case Transport of
       ssl -> ssl:setopts(Sock, [{packet, http}]);
       _ -> inet:setopts(Sock, [{packet, http}])
    end,
    ok = Transport:send(Sock, Req),
    {reply, ok, State#state{sock = Sock, readystate = ?CONNECTING}};
handle_call(get_readystate, _From, State = #state{readystate = S}) ->
    {reply, S, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.
handle_cast(
  {send, Op, Payload},
  State = #state{transport = Transport, sock = Sock, readystate = ?OPEN}) ->
    ok = Transport:send(Sock, frame(Op,Payload)),
    {noreply, State}.

handle_info({frame, OpCode, Payload}, State) ->
    handle_frame(OpCode, Payload, State);
handle_info({_, _, {http_response, {1, 1} , Status, _}},
            State = #state{readystate = ?CONNECTING}) ->
    case Status of 
        101 -> 
            {noreply, State};
        _ -> 
            {noreply, State#state{readystate = ?CLOSED}}
    end;
handle_info({_, _, {http_header, _, Name, _, Value}},
            State = #state{readystate = ?CONNECTING, headers = Hs}) ->
    {noreply, State#state{headers = [{Name, Value} | Hs]}};
handle_info({_, _, http_eoh}, State = #state{readystate = ?CONNECTING}) ->
    {noreply, handshake(State)};
handle_info({tcp_closed, _Socket}, State) ->
    close_websocket(tcp_closed, State);
handle_info({ssl_closed, _Socket}, State) ->
    close_websocket(ssl_closed, State);
handle_info({tcp_error, _Socket, Reason},State) ->
    close_websocket(Reason, State);
handle_info({error, Msg}, State) ->
    close_websocket(Msg, State);
handle_info({Transport, _, _}, State = #state{transport = Transport}) ->
    {noreply, State};
handle_info(Msg, State = #state{handler = Handler, handlerstate = HandlerState}) ->
    HandlerResponse = Handler:ws_info(Msg, HandlerState),
    {noreply, handle_response(HandlerResponse, State)}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------------
wait_for_connect(Pid) ->
    timer:sleep(2),
    case get_readystate(Pid) of 
        ?DISCONNECTED ->
            wait_for_connect(Pid);
        ?CONNECTING ->
            wait_for_connect(Pid);
        ?OPEN->
            {Pid, open};
        ?CLOSED ->
            {Pid, closed}
    end.

close_websocket(_, State = #state{readystate = ?CLOSED}) ->
    {noreply, State};
close_websocket(Msg, State = #state{handler = Handler, handlerstate = HandlerState}) ->
    Handler:ws_terminate(Msg, HandlerState),
    {noreply, State#state{readystate = ?CLOSED}}.
    
handle_frame(OpCode, Payload, State = #state{sock = Sock, 
                                             transport = Transport, 
                                             handler = Handler, 
                                             handlerstate = HandlerState}) ->
    case OpCode of
        ping ->
            ok = Transport:send(Sock, frame(?OP_PONG, <<>>)),
            {noreply, State}; 
        close ->
            Transport:close(Sock),
            close_websocket(close, State);
        _ -> 
            HandlerResponse = Handler:ws_handle({OpCode, Payload}, HandlerState),
            {noreply, handle_response(HandlerResponse, State)}
    end.

handle_response({ok, HandlerState}, State) ->
    State#state{handlerstate=HandlerState};    
handle_response({reply, {binary, Bin}, HandlerState}, State) ->
    send_binary(self(), Bin),
    State#state{handlerstate=HandlerState};    
handle_response({reply, {text, Msg}, HandlerState}, State) ->
    send_text(self(), Msg),
    State#state{handlerstate=HandlerState}.    

receive_loop(Pid, Transport, Sock, Data, Cop, FrameBuf) -> 
    case recv_data(Sock, Data, Transport) of
	{Op, Payload, 0, RestData}  ->
            NewFrameBuf = <<FrameBuf/binary, Payload/binary>>,
            receive_loop(Pid, Transport, Sock, RestData, op_cont(Cop, Op), NewFrameBuf);
	{Op, Payload, 1, RestData} ->
	    Opcode = op_cont(Cop, Op),
	    FrameData = <<FrameBuf/binary, Payload/binary>>,
            Pid ! {frame, Opcode, FrameData}, 
            receive_loop(Pid, Transport, Sock, RestData, Opcode, <<>>);
	Msg -> Pid ! {error, Msg}
    end.
    
op_cont(Cop, ?OP_CONT) ->
    Cop;
op_cont(_, Op) ->
    Op.

key() ->
    {A1,A2,A3} = now(),
    random:seed(A1,A2,A3),
    binary_to_list(
      base64:encode(<< <<(random:uniform(256))>> || _N <- lists:seq(1,16)>>)).

initial_request(Host,Port, Path, Key) ->
    "GET "++ Path ++" HTTP/1.1\r\n" ++
    "Host: " ++ Host ++ ":" ++ integer_to_list(Port) ++ "\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Sec-WebSocket-Version: 13\r\n" ++
    "Sec-WebSocket-Key: " ++ Key ++ "\r\n\r\n".

handshake(State = #state{readystate = ?CONNECTING, sock = Sock, key = Key,
                         transport = Transport, headers = Headers}) ->
    "upgrade" = string:to_lower(proplists:get_value('Connection', Headers)),
    "websocket" = string:to_lower(proplists:get_value('Upgrade', Headers)),
    Accept = proplists:get_value("Sec-Websocket-Accept", Headers),
    MagicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
    Expected = binary_to_list(base64:encode(crypto:hash(sha, Key ++ MagicString))),
    case Accept =:= Expected of
        true ->
            Transport:setopts(Sock, [{packet, raw},{active, false},{packet_size,0}]),
            spawn_link(?MODULE, receive_loop, [self(), Transport, Sock, <<>>, ?OP_CONT, <<>>]),
            State#state{readystate = ?OPEN};
        _ ->
            State#state{readystate = ?CLOSED}
    end.


mask(Data, Mask) ->
    << MaskKey:32 >> = Mask,
    mask(MaskKey, Data, <<>>).
mask(_, <<>>, Acc) ->
    Acc;
mask(Mask, << D:32, Rest/bits >>, Acc) ->
    T = D bxor Mask,
    mask(Mask, Rest, << Acc/binary, T:32 >>);
mask(Mask, << D:24 >>, Acc) ->
    << MaskPart:24, _:8 >> = << Mask:32 >>,
    T = D bxor MaskPart,
    << Acc/binary, T:24 >>;
mask(Mask, << D:16 >>, Acc) ->
    << MaskPart:16, _:16 >> = << Mask:32 >>,
    T = D bxor MaskPart,
    << Acc/binary, T:16 >>;
mask(Mask, << D:8 >>, Acc) ->
    << MaskPart:8, _:24 >> = << Mask:32 >>,
    T = D bxor MaskPart,
    << Acc/binary, T:8 >>.

unmask(0, Data) ->
    Data;
unmask(1, << Mask:32, Data/bits >> ) ->
    mask(Data, <<Mask:32>>).

op_to_atom(?OP_CONT) -> cont;
op_to_atom(?OP_TEXT) -> text;
op_to_atom(?OP_BINARY) -> binary;
op_to_atom(?OP_PING) -> ping;
op_to_atom(?OP_PONG) -> pong;
op_to_atom(?OP_CLOSE) -> close.

contains_full_frame(Data) when byte_size(Data) < 2 ->
     false;
contains_full_frame(<< _:9, Data/bits >>) ->
    case decode_len(Data) of
	error -> 
	    false;
	{Len, Rest} -> 
	    byte_size(Rest) >= Len
    end.
  
recv_data(Sock, Buf, Transport) ->
    {Stat, B} = Transport:recv(Sock, 0),
    case Stat of
         ok ->
            NewBuf = << Buf/binary, B/binary >>, 
	    case contains_full_frame(NewBuf) of
		true ->
		    unframe(NewBuf);
		_ ->
		    recv_data(Sock, NewBuf, Transport)
	    end; 
	error -> error
    end.

unframe(<< F:1, _:3, Op:4, M:1, Data/bits >>) ->
    {Len, Buf} = decode_len(Data),
    <<Payload:Len/bytes,RestBuf/bytes>> = Buf,
    {op_to_atom(Op),unmask(M,Payload),F,RestBuf}.

frame(Op, Data) ->
    F = 1,
    R = 0,
    M = 1,
    Size = byte_size( Data ),
    Len = encode_len(Size),
    Mask = random:uniform(4294967296),
    MaskedData = mask(Data, <<Mask:32>>),
    << F:1, R:3, Op:4, M:1, Len/bits, Mask:32, MaskedData/binary >>.

encode_len(Len) when Len < 126 ->
    << Len:7 >>;
encode_len(Len) when Len =< 16#ffff ->
    << 126:7, Len:16 >>;
encode_len(Len) when Len =< 16#7fffffffffffffff ->
    << 127:7, Len:64 >>.

decode_len(<<127:7, Len:64, Rest/bytes>>) ->
    {Len, Rest};
decode_len(<<126:7, Len:16, Rest/bytes>>) ->
    {Len, Rest};
decode_len(<<Len:7, Rest/bytes>>) ->
    case Len of 
         127 -> error;
         126 -> error;
         _ -> {Len, Rest}
    end.

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
