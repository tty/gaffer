-module(gaffer_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%----------------------------------------------------------------------------
%% Application callbacks
%%----------------------------------------------------------------------------

start(_StartType, _StartArgs) ->
    gaffer_sup:start_link().

stop(_State) ->
    ok.

%% Local variables:
%% mode: erlang
%% fill-column: 78
%% coding: latin-1
%% End:
