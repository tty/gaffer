-module(inbox_ws_handler).

-behaviour(gaffer_ws_client_handler).

-export([
         init/1,
         ws_handle/2,
         ws_info/2,
         ws_terminate/2
        ]).

-record(state, {inbox}).

%%----------------------------------------------------------------------------
%%  websocket_client_handler callbacks
%%----------------------------------------------------------------------------

init(_Args) ->
    {ok, #state{inbox = []}}.

ws_handle({text, Msg}, State = #state{inbox = Inbox}) ->
    {ok, State#state{inbox = [Msg | Inbox]}};
ws_handle(_Msg, State) ->
    {ok, State}.

ws_info({send, Msg}, State) ->
    {reply, {text, Msg}, State};
ws_info({dequeue, From}, State = #state{inbox = []}) ->
    From ! undefined,
    {ok, State};
ws_info({dequeue, From}, State = #state{inbox = Inbox}) ->
   From ! lists:last(Inbox),
   {ok, State#state{inbox = lists:sublist(Inbox, length(Inbox) - 1)}};
ws_info(_Msg, State) ->
    {ok, State}.

ws_terminate(_Msg, State) ->
    {ok, State}.

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
