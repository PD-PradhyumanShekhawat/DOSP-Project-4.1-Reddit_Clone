
-module(reddit_client).

-export([
    start_link/1,
    stop/1,
    register/2
]).

%% Starts an independent client actor connected to the engine.
start_link(EnginePid) when is_pid(EnginePid) ->
    spawn_link(fun() -> loop(EnginePid) end).

%% Stops the client actor.
stop(ClientPid) when is_pid(ClientPid) ->
    ClientPid ! stop,
    ok.

%% Requests account registration through the client actor.
register(ClientPid, Username) ->
    call(ClientPid, {register, Username}).

%% Sends a request to the client actor and waits for its response.
call(ClientPid, Request) ->
    Ref = make_ref(),
    ClientPid ! {call, self(), Ref, Request},

    receive
        {client_reply, Ref, Result} ->
            Result
    after 6000 ->
        {error, timeout}
    end.

%% Client actor loop.
loop(EnginePid) ->
    receive
        {call, From, Ref, {register, Username}} ->
            EngineRef = make_ref(),

            EnginePid ! {
                request,
                self(),
                EngineRef,
                {register, Username}
            },

            receive
                {reply, EngineRef, Result} ->
                    From ! {client_reply, Ref, Result},
                    loop(EnginePid)
            after 5500 ->
                From ! {client_reply, Ref, {error, engine_timeout}},
                loop(EnginePid)
            end;

        stop ->
            ok;

        _UnexpectedMessage ->
            loop(EnginePid)
    end.
