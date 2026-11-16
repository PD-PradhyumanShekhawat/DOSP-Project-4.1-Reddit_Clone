
-module(reddit_engine).

-export([
    start_link/0,
    stop/1,
    register_account/2,
    account_count/1,
    create_subreddit/3,
    join_subreddit/3,
    leave_subreddit/3,
    subreddit_info/2,
    create_post/4,
    get_feed/2
]).

start_link() ->
    spawn_link(fun() ->
        loop(#{
            accounts => #{},
            subreddits => #{},
            posts => [],
            next_post_id => 1
        })
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

create_post(EnginePid, Username, SubredditName, Content) ->
    request(EnginePid, {create_post, Username, SubredditName, Content}).

get_feed(EnginePid, Username) ->
    request(EnginePid, {get_feed, Username}).

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
                From, Ref, {ok, maps:size(Accounts)}, State
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

        {request, From, Ref,
         {create_post, Username, SubredditName, Content}} ->
            {Result, NewState} =
                create_post_state(Username, SubredditName, Content, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_feed, Username}} ->
            Result = get_user_feed(Username, State),
            reply_and_continue(From, Ref, Result, State);

        stop ->
            ok;

        _UnexpectedMessage ->
            loop(State)
    end.

reply_and_continue(From, Ref, Result, NewState) ->
    From ! {reply, Ref, Result},
    loop(NewState).

%% Account registration

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

%% Subreddit creation

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

%% Join a subreddit

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

%% Leave a subreddit

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

%% Subreddit information

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

%% Create a text post

create_post_state(Username, SubredditName, Content, State) ->
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
                            case validate_content(Content) of
                                {error, Reason} ->
                                    {{error, Reason}, State};
                                ok ->
                                    PostId = maps:get(next_post_id, State),
                                    Post = #{
                                        id => PostId,
                                        author => Username,
                                        subreddit => SubredditName,
                                        content => Content,
                                        timestamp =>
                                            erlang:system_time(second)
                                    },
                                    Posts = [Post | maps:get(posts, State)],
                                    NewState = State#{
                                        posts := Posts,
                                        next_post_id := PostId + 1
                                    },
                                    {{ok, PostId}, NewState}
                            end
                    end
            end
    end.

%% Return posts from all subreddits the user has joined.
%% Posts are stored newest first.

get_user_feed(Username, State) ->
    Accounts = maps:get(accounts, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            Subreddits = maps:get(subreddits, State),
            JoinedSubreddits = [
                Name
                || {Name, Subreddit} <- maps:to_list(Subreddits),
                   maps:is_key(Username, maps:get(members, Subreddit))
            ],
            Feed = [
                Post
                || Post <- maps:get(posts, State),
                   lists:member(
                       maps:get(subreddit, Post),
                       JoinedSubreddits
                   )
            ],
            {ok, Feed}
    end.

%% Validation helpers

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

validate_content(Content)
        when is_list(Content), length(Content) > 0 ->
    case string:trim(Content) of
        [] -> {error, empty_content};
        _ -> ok
    end;

validate_content(Content)
        when is_binary(Content), byte_size(Content) > 0 ->
    case string:trim(Content) of
        <<>> -> {error, empty_content};
        _ -> ok
    end;

validate_content(_) ->
    {error, empty_content}.
