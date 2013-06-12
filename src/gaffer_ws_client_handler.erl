-module(gaffer_ws_client_handler).

-type state() :: any().

-callback init(list()) ->
    {ok, state()}.

-callback ws_handle({text | binary | pong, binary()}, state()) ->
    {ok, state()}
        | {reply, {text | binary, binary()}, state()}.

-callback ws_info(any(), state()) ->
    {ok, state()}
        | {reply, {text | binary, binary()}, state()}.

-callback ws_terminate(any(), state()) ->
    ok.
