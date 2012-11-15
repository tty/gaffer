-module(gaffer_ws_client).

-behaviour(gen_server).

%% API
-export([start_link/1]).
-export([connect/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([key/0]).


-define(SERVER, ?MODULE). 

-record(state, {key,host,port,path,sock}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------
connect(Pid) ->
    gen_server:cast(Pid, connect).

start_link(Url) ->
    gen_server:start_link(?MODULE, [Url], []).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Url]) ->
    {ok,{ws,[],Host,Port,Path,[]}} = http_uri:parse(Url),
    {ok, #state{key = key(), host = Host, port = Port, path = Path}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(connect, State = #state{host = Host, port = Port, path = _Path}) ->
    {ok, Sock} = gen_tcp:connect(Host, Port, []),
    {noreply, State#state{sock = Sock}}.

handle_info(_Info, State) ->
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
    base64:encode(<< <<(random:uniform(256))>> || _N <- lists:seq(1,16) >>).

%% handshake_request(Url) ->
%%     {ok,{ws,[],Host,Port,Path,[]}} = http_uri:parse(Url).
    
%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
