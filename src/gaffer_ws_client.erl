-module(gaffer_ws_client).

-behaviour(gen_server).

%% API
-export([connect/1]).
-export([send_text/2, send_binary/2]).
-export([ping/1]).
-export([start_link/1]).
-export([get_frame/1]).
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
                key,
                host, port, path,
                sock,
                headers,
                data_buffer = <<>>,
                frame_buffer = <<>>,
                op_cont}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

connect(Pid) ->
    ok = gen_server:call(Pid, connect),
    wait_for_connect(Pid).

get_readystate(Pid) ->
    gen_server:call(Pid, get_readystate).

get_frame(Pid) ->
    gen_server:call(Pid, get_frame).

send_text(Pid, Text) ->
    gen_server:cast(Pid, {send, ?OP_TEXT, Text}).

send_binary(Pid, Data) ->
    gen_server:cast(Pid, {send, ?OP_BINARY, Data}).

ping(Pid) ->
    gen_server:cast(Pid, {send, ?OP_PING, <<>>}).

start_link(Url) ->
    gen_server:start_link(?MODULE, [Url], []).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Url]) ->
    {ok,{ws,[],Host,Port,Path,[]}} = http_uri:parse(Url),
    {ok, #state{readystate = ?DISCONNECTED,
                key = key(),
                host = Host, port = Port, path = Path}}.

handle_call(connect, _From, State = #state{host = Host, port = Port,
                                    path = Path, key = Key}) ->
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {packet, 0},
                                              {active,true}]),
    Req = initial_request(Host, Port, Path, Key),
    inet:setopts(Sock, [{packet, http}]),
    ok = gen_tcp:send(Sock, Req),
    {reply, ok, State#state{sock = Sock}};
handle_call(get_readystate, _From, State = #state{readystate = S}) ->
    {reply, S, State};
handle_call(get_frame, _From, State = #state{readystate = ?OPEN}) ->
    {Result, NewState} = receive_frame(State),
    {reply, Result, NewState};
handle_call(get_frame, _From, State) ->
    {reply, {error,connection_not_open}, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.
handle_cast(
  {send, Op, Data},
  State = #state{sock = Sock, readystate = ?OPEN}) ->
    ok = gen_tcp:send(Sock, frame(Op,Data)),
    {noreply, State}.

handle_info({http, _, {http_response, {1, 1} , 101, _}},
            State = #state{readystate = ?DISCONNECTED}) ->
    {noreply, State#state{readystate = ?CONNECTING}};
handle_info({http, _, {http_header, _, Name, _, Value}},
            State = #state{readystate = ?CONNECTING, headers = Hs}) ->
    {noreply, State#state{headers = [{Name, Value} | Hs]}};
handle_info({http, _, http_eoh}, State = #state{readystate = ?CONNECTING}) ->
    {noreply, handshake(State)};
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State#state{readystate = ?CLOSED}};
handle_info({tcp_error, _Socket, _Reason},State) ->
    {stop, tcp_error, State#state{readystate = ?CLOSED}};
handle_info(_, State) ->
    {noreply, State}.

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

receive_frame(State = #state{sock = Sock, 
                             data_buffer = Data, 
                             op_cont = Cop,
                             frame_buffer = FrameBuf}) ->
    case recv_data(Sock, Data) of
	{Op, Payload, 0, RestData}  -> 
	    receive_frame(State#state{frame_buffer = <<FrameBuf/binary, Payload/binary>>,
				      data_buffer = RestData,
				      op_cont = op_cont(Cop, Op)});
	{Op, Payload, 1, RestData} ->
	    Opcode = op_cont(Cop, Op),
	    CompleteFrame = {Opcode, <<FrameBuf/binary, Payload/binary>>},
	    handle_control(Opcode, Sock),
	    {CompleteFrame, State#state{frame_buffer = <<>>, data_buffer = RestData}};
	_ -> {error, State#state{readystate = ?CLOSED, frame_buffer = <<>>, data_buffer = <<>>}}
    end.

handle_control(close, Sock) ->
    gen_tcp:close(Sock);
handle_control(ping, Sock) ->
    gen_tcp:send(Sock, frame(?OP_PONG,<<>>));
handle_control(_, _) ->
    ok.

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
                         headers = Headers}) ->
    "upgrade" = string:to_lower(proplists:get_value('Connection', Headers)),
    "websocket" = string:to_lower(proplists:get_value('Upgrade', Headers)),
    Accept = proplists:get_value("Sec-Websocket-Accept", Headers),
    MagicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
    Expected = binary_to_list(base64:encode(crypto:sha(Key ++ MagicString))),
    case Accept =:= Expected of
        true ->
            inet:setopts(Sock, [{packet, raw},{active, false},{packet_size,0}]),
            State#state{readystate = ?OPEN};
        _ ->
            State#state{readystate = ?CLOSED}
    end.

mask(<<>>, _) ->
    <<>>;
mask(<<D:24>>, <<M:24, _:8>>) ->
    crypto:exor(<<D:24>>, <<M:24>>);
mask(<<D:16>>, <<M:16, _:16>>) ->
    crypto:exor(<<D:16>>, <<M:16>>);
mask(<<D>>, <<M, _:24>>) ->
    crypto:exor(<<D:8>>, <<M:8>>);
mask(<<D:32, Rest/bits >>, M) ->
    Data = crypto:exor(<<D:32>>, M),
    MaskedRest = mask(Rest, M),
    << Data:32/bits, MaskedRest/bits >>.

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
  
recv_data(Sock, Buf) ->
    {Stat, B} = gen_tcp:recv(Sock, 0),
    case Stat of
         ok ->
            NewBuf = << Buf/binary, B/binary >>, 
	    case contains_full_frame(NewBuf) of
		true ->
		    unframe(NewBuf);
		_ ->
		    recv_data(Sock, NewBuf)
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
