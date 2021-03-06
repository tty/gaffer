-module(gaffer).

%% API
-export([start/0,stop/0]).
-export([new_client/2]).
-export([send_text/2,send_binary/2,ping/1]).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start() ->
    application:start(gaffer).

stop() ->
    application:stop(gaffer).

new_client(Handler, Url) ->
    {ok, Pid} = supervisor:start_child(gaffer_sup, [Handler, Url]),
    gaffer_ws_client:connect(Pid).

send_binary(Client,Data) ->
    gaffer_ws_client:send_binary(Client, Data).
    
send_text(Client,Data) ->
    gaffer_ws_client:send_text(Client, Data).

ping(Client) ->
    gaffer_ws_client:ping(Client).

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
