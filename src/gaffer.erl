-module(gaffer).

%% API
-export([start/0,stop/0]).
-export([new_client/1]).
-export([connect/1]).
-export([send/2]).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start() ->
    application:start(gaffer).

stop() ->
    application:stop(gaffer).

new_client(Url) ->
    {ok, Pid} = supervisor:start_child(gaffer_sup, [Url]),
    Pid.

connect(Client) ->
    gaffer_ws_client:connect(Client).

send(Client,Data) ->
    gaffer_ws_client:send(Client, Data).
    
%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
