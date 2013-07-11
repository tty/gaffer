-module(active_ws_handler).

-behaviour(gaffer_ws_client_handler).

-export([
         init/1,
         ws_handle/2,
         ws_info/2,
         ws_terminate/2
        ]).

-record(state, {receivers}).

%%----------------------------------------------------------------------------
%%  websocket_client_handler callbacks
%%----------------------------------------------------------------------------

init(_Args) ->
    {ok, #state{receivers = []}}.

ws_handle({text, Msg}, S = #state{receivers = Rs}) ->
    [R ! {ws_msg, Msg} || R <- Rs],
    {ok, S};
ws_handle(_Msg, S) ->
    {ok, S}.

ws_info({register, R}, S = #state{receivers = Rs}) ->
    {ok, S#state{receivers = Rs ++ [R]}};
ws_info({send, Msg}, S) ->
    {reply, {text, Msg}, S};
ws_info(_Msg, S) ->
    {ok, S}.

ws_terminate(_Msg, S) ->
    {ok, S}.

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
