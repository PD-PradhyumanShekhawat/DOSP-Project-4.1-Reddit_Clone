
-module(reddit_engine).

-export([
    start_link/0,
    stop/1,
    register_account/2,
    account_count/1
]).

%% Starts the central Reddit engine process.
start_link() ->
    spawn_link(fun() -> loop(#{}) end).

%% Stops the engine.
stop(EnginePid) when is_pid(EnginePid) ->
    EnginePid ! stop,
    ok.

%% Engine-level registration request.
register_account(EnginePid, Username) ->
    request(EnginePid, {register, Username}).

%% Returns the number of registered accounts.
account_count(EnginePid) ->
    request(EnginePid, account_count).

%% Sends a request and waits for the engine's response.
request(EnginePid, Request) ->
    Ref = make_ref(),
    EnginePid ! {request, self(), Ref, Request},

    receive
        {reply, Ref, Result} ->
            Result
    after 5000 ->
        {error, timeout}
    end.

%% Central engine loop.
%% The engine owns and updates the account map.
loop(Accounts) ->
    receive
        {request, From, Ref, {register, Username}} ->
            case validate_username(Username) of
                ok ->
                    case maps:is_key(Username, Accounts) of
                        true ->
                            From ! {reply, Ref, {error, username_taken}},
                            loop(Accounts);

                        false ->
                            Account = #{
                                username => Username
                            },

                            UpdatedAccounts =
                                maps:put(Username, Account, Accounts),

                            From ! {reply, Ref, {ok, registered}},
                            loop(UpdatedAccounts)
                    end;

                {error, Reason} ->
                    From ! {reply, Ref, {error, Reason}},
                    loop(Accounts)
            end;

        {request, From, Ref, account_count} ->
            Count = maps:size(Accounts),
            From ! {reply, Ref, {ok, Count}},
            loop(Accounts);

        stop ->
            ok;

        _UnexpectedMessage ->
            loop(Accounts)
    end.

%% Basic username validation.
validate_username(Username)
        when is_list(Username), length(Username) > 0 ->
    case string:trim(Username) of
        [] ->
            {error, invalid_username};
        _ ->
            ok
    end;

validate_username(Username)
        when is_binary(Username), byte_size(Username) > 0 ->
    case string:trim(Username) of
        <<>> ->
            {error, invalid_username};
        _ ->
            ok
    end;

validate_username(_) ->
    {error, invalid_username}.
