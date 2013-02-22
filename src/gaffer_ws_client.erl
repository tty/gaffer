-module(gaffer_ws_client).

-behaviour(gen_server).

%% API
-export([connect/1]).
-export([get_frames/1, flush_frames/1]).
-export([send_text/2, send_binary/2]).
-export([ping/1]).
-export([start_link/1]).

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
                buffer = <<>>,
                op_cont,
                recv_frames = []}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

connect(Pid) ->
    gen_server:cast(Pid, connect).

get_frames(Pid) ->
    gen_server:call(Pid, get_frames).

flush_frames(Pid) ->
    gen_server:cast(Pid, flush_frames).

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

handle_call(get_frames, _From, State = #state{recv_frames = Fs}) ->
    {reply, Fs, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(flush_frames, State) ->
    {noreply, State#state{recv_frames = []}};
handle_cast(connect, State = #state{host = Host, port = Port,
                                    path = Path, key = Key}) ->
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {packet, 0},
                                              {active,true}]),
    Req = initial_request(Host, Port, Path, Key),
    inet:setopts(Sock, [{packet, http}]),
    ok = gen_tcp:send(Sock, Req),
    {noreply, State#state{sock = Sock}};
handle_cast(
  {send, Op, Data},
  State = #state{sock = Sock, readystate = ?OPEN}
 ) ->
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
handle_info({tcp,_,Frame}, State = #state{readystate = ?OPEN,
                                          sock = Sock,
                                          op_cont = Cop,
                                          buffer = Buffer,
                                          recv_frames = Frames}) ->
    New_state = case unframe(Frame) of
                    {Op, Data, 0} ->
                        State#state{buffer = <<Buffer/binary, Data/binary>>,
                                    op_cont = op_cont(Cop, Op)};
                    {Op, Data, 1} ->
                        Opcode = op_cont(Cop, Op),
                        NewFrame = {Opcode, <<Buffer/binary, Data/binary>>},
                        handle_control(Opcode, Sock),
                        State#state{buffer = <<>>,
                                    recv_frames = [NewFrame | Frames]}
                end,
    {noreply, New_state};
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

handle_control(close, Sock) ->
    gen_tcp:close(Sock);
handle_control(ping, Sock) ->
    gen_tcp:send(Sock, frame(?OP_PONG,<<>>));
handle_control(_,_) ->
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
            inet:setopts(Sock, [{packet, raw}, {buffer, 1400000},
                                {packet_size,0}]),
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

op_to_atom(?OP_TEXT) -> text;
op_to_atom(?OP_BINARY) -> binary;
op_to_atom(?OP_PING) -> ping;
op_to_atom(?OP_PONG) -> pong;
op_to_atom(?OP_CLOSE) -> close.

unframe(<< F:1, _:3, Op:4, M:1, Data/bits >>) ->
    {Len, Rest} = decode_len(Data),
    Len = byte_size(Rest),
    {op_to_atom(Op),unmask(M,Rest),F}.

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
encode_len(Len) when Len =< 65535 ->
    << 126:7, Len:16 >>;
encode_len(Len) when Len =< 18446744073709551615 ->
    << 127:7, Len:64 >>.

decode_len(<<127:7, Len:64, Rest/bytes>>) ->
    {Len, Rest};
decode_len(<<126:7, Len:16, Rest/bytes>>) ->
    {Len, Rest};
decode_len(<<Len:7, Rest/bytes>>) ->
    {Len, Rest}.

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
