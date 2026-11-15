
-module(reddit_engine).

-export([
    start_link/0,
    stop/1,
    register_account/2,
    account_count/1,
    create_subreddit/3,
    join_subreddit/3,
    leave_subreddit/3,
    subreddit_info/2
]).

start_link() ->
    spawn_link(fun() ->
        loop(#{accounts => #{}, subreddits => #{}})
    end).

stop(EnginePid) when is_pid(EnginePid) ->
    EnginePid ! stop,
    ok.

register_account(EnginePid, Username) ->
    request(EnginePid, {register, Username}).

account_count(EnginePid) ->
    request(EnginePid, account_count).

create_subreddit(EnginePid, Username, SubredditName) ->
    request(EnginePid, {create_subreddit, Username, SubredditName}).

join_subreddit(EnginePid, Username, SubredditName) ->
    request(EnginePid, {join_subreddit, Username, SubredditName}).

leave_subreddit(EnginePid, Username, SubredditName) ->
    request(EnginePid, {leave_subreddit, Username, SubredditName}).

subreddit_info(EnginePid, SubredditName) ->
    request(EnginePid, {subreddit_info, SubredditName}).

request(EnginePid, Request) ->
    Ref = make_ref(),
    EnginePid ! {request, self(), Ref, Request},

    receive
        {reply, Ref, Result} ->
            Result
    after 5000 ->
        {error, timeout}
    end.

loop(State) ->
    receive
        {request, From, Ref, {register, Username}} ->
            {Result, NewState} = register_user(Username, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, account_count} ->
            Accounts = maps:get(accounts, State),
            reply_and_continue(
                From,
                Ref,
                {ok, maps:size(Accounts)},
                State
            );

        {request, From, Ref,
         {create_subreddit, Username, SubredditName}} ->
            {Result, NewState} =
                create_subreddit_state(Username, SubredditName, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref,
         {join_subreddit, Username, SubredditName}} ->
            {Result, NewState} =
                join_subreddit_state(Username, SubredditName, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref,
         {leave_subreddit, Username, SubredditName}} ->
            {Result, NewState} =
                leave_subreddit_state(Username, SubredditName, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {subreddit_info, SubredditName}} ->
            Result = get_subreddit_info(SubredditName, State),
            reply_and_continue(From, Ref, Result, State);

        stop ->
            ok;

        _UnexpectedMessage ->
            loop(State)
    end.

reply_and_continue(From, Ref, Result, NewState) ->
    From ! {reply, Ref, Result},
    loop(NewState).

register_user(Username, State) ->
    case validate_name(Username) of
        ok ->
            Accounts = maps:get(accounts, State),
            case maps:is_key(Username, Accounts) of
                true ->
                    {{error, username_taken}, State};
                false ->
                    Account = #{username => Username},
                    UpdatedAccounts = maps:put(Username, Account, Accounts),
                    {{ok, registered},
                     State#{accounts := UpdatedAccounts}}
            end;
        Error ->
            {Error, State}
    end.

create_subreddit_state(Username, SubredditName, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case {maps:is_key(Username, Accounts), validate_name(SubredditName)} of
        {false, _} ->
            {{error, account_not_found}, State};

        {true, {error, Reason}} ->
            {{error, Reason}, State};

        {true, ok} ->
            case maps:is_key(SubredditName, Subreddits) of
                true ->
                    {{error, subreddit_exists}, State};

                false ->
                    Subreddit = #{
                        name => SubredditName,
                        creator => Username,
                        members => #{Username => true}
                    },

                    UpdatedSubreddits =
                        maps:put(SubredditName, Subreddit, Subreddits),

                    {{ok, subreddit_created},
                     State#{subreddits := UpdatedSubreddits}}
            end
    end.

join_subreddit_state(Username, SubredditName, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};

        true ->
            case maps:find(SubredditName, Subreddits) of
                error ->
                    {{error, subreddit_not_found}, State};

                {ok, Subreddit} ->
                    Members = maps:get(members, Subreddit),

                    case maps:is_key(Username, Members) of
                        true ->
                            {{error, already_member}, State};

                        false ->
                            UpdatedMembers = maps:put(Username, true, Members),
                            UpdatedSubreddit =
                                Subreddit#{members := UpdatedMembers},

                            UpdatedSubreddits =
                                maps:put(
                                    SubredditName,
                                    UpdatedSubreddit,
                                    Subreddits
                                ),

                            {{ok, joined},
                             State#{subreddits := UpdatedSubreddits}}
                    end
            end
    end.

leave_subreddit_state(Username, SubredditName, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};

        true ->
            case maps:find(SubredditName, Subreddits) of
                error ->
                    {{error, subreddit_not_found}, State};

                {ok, Subreddit} ->
                    Members = maps:get(members, Subreddit),

                    case maps:is_key(Username, Members) of
                        false ->
                            {{error, not_member}, State};

                        true ->
                            UpdatedMembers = maps:remove(Username, Members),
                            UpdatedSubreddit =
                                Subreddit#{members := UpdatedMembers},

                            UpdatedSubreddits =
                                maps:put(
                                    SubredditName,
                                    UpdatedSubreddit,
                                    Subreddits
                                ),

                            {{ok, left},
                             State#{subreddits := UpdatedSubreddits}}
                    end
            end
    end.

get_subreddit_info(SubredditName, State) ->
    Subreddits = maps:get(subreddits, State),

    case maps:find(SubredditName, Subreddits) of
        error ->
            {error, subreddit_not_found};

        {ok, Subreddit} ->
            Members = maps:get(members, Subreddit),
            {ok, #{
                name => maps:get(name, Subreddit),
                creator => maps:get(creator, Subreddit),
                members => maps:keys(Members),
                member_count => maps:size(Members)
            }}
    end.

validate_name(Name)
        when is_list(Name), length(Name) > 0 ->
    case string:trim(Name) of
        [] -> {error, invalid_name};
        _ -> ok
    end;

validate_name(Name)
        when is_binary(Name), byte_size(Name) > 0 ->
    case string:trim(Name) of
        <<>> -> {error, invalid_name};
        _ -> ok
    end;

validate_name(_) ->
    {error, invalid_name}.
