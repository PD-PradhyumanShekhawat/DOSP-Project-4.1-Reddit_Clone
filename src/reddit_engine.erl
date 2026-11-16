
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
    get_feed/2,
    add_comment/5,
    get_post_comments/2
]).

start_link() ->
    spawn_link(fun() ->
        loop(#{
            accounts => #{},
            subreddits => #{},
            posts => [],
            next_post_id => 1,
            comments => [],
            next_comment_id => 1
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

add_comment(EnginePid, Username, PostId, ParentCommentId, Content) ->
    request(
        EnginePid,
        {add_comment, Username, PostId, ParentCommentId, Content}
    ).

get_post_comments(EnginePid, PostId) ->
    request(EnginePid, {get_post_comments, PostId}).

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

        {request, From, Ref,
         {add_comment, Username, PostId, ParentCommentId, Content}} ->
            {Result, NewState} =
                add_comment_state(
                    Username, PostId, ParentCommentId, Content, State
                ),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_post_comments, PostId}} ->
            Result = get_post_comments_state(PostId, State),
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

%% Subreddit management

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

%% Post creation

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

%% Comment creation and hierarchical replies

add_comment_state(Username, PostId, ParentCommentId, Content, State) ->
    Accounts = maps:get(accounts, State),
    Posts = maps:get(posts, State),
    Comments = maps:get(comments, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case find_post(PostId, Posts) of
                error ->
                    {{error, post_not_found}, State};
                {ok, Post} ->
                    SubredditName = maps:get(subreddit, Post),
                    Subreddits = maps:get(subreddits, State),
                    Subreddit = maps:get(SubredditName, Subreddits),
                    Members = maps:get(members, Subreddit),

                    case maps:is_key(Username, Members) of
                        false ->
                            {{error, not_member}, State};
                        true ->
                            case validate_content(Content) of
                                {error, Reason} ->
                                    {{error, Reason}, State};
                                ok ->
                                    validate_and_store_comment(
                                        Username,
                                        PostId,
                                        ParentCommentId,
                                        Content,
                                        Comments,
                                        State
                                    )
                            end
                    end
            end
    end.

validate_and_store_comment(
    Username, PostId, ParentCommentId, Content, Comments, State
) ->
    case validate_parent_comment(PostId, ParentCommentId, Comments) of
        ok ->
            CommentId = maps:get(next_comment_id, State),
            Comment = #{
                id => CommentId,
                post_id => PostId,
                parent_id => ParentCommentId,
                author => Username,
                content => Content,
                timestamp => erlang:system_time(second)
            },
            UpdatedComments = [Comment | Comments],
            NewState = State#{
                comments := UpdatedComments,
                next_comment_id := CommentId + 1
            },
            {{ok, CommentId}, NewState};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

validate_parent_comment(_PostId, none, _Comments) ->
    ok;
validate_parent_comment(PostId, ParentCommentId, Comments)
        when is_integer(ParentCommentId) ->
    case find_comment(ParentCommentId, Comments) of
        error ->
            {error, parent_comment_not_found};
        {ok, ParentComment} ->
            case maps:get(post_id, ParentComment) =:= PostId of
                true -> ok;
                false -> {error, parent_comment_wrong_post}
            end
    end;
validate_parent_comment(_PostId, _ParentCommentId, _Comments) ->
    {error, invalid_parent_comment_id}.

get_post_comments_state(PostId, State) ->
    case find_post(PostId, maps:get(posts, State)) of
        error ->
            {error, post_not_found};
        {ok, _Post} ->
            Comments = maps:get(comments, State),
            Tree = build_comment_tree(PostId, none, Comments),
            {ok, Tree}
    end.

build_comment_tree(PostId, ParentId, Comments) ->
    DirectComments = lists:sort(
        fun(A, B) -> maps:get(id, A) < maps:get(id, B) end,
        [
            Comment
            || Comment <- Comments,
               maps:get(post_id, Comment) =:= PostId,
               maps:get(parent_id, Comment) =:= ParentId
        ]
    ),

    [
        Comment#{
            replies => build_comment_tree(
                PostId,
                maps:get(id, Comment),
                Comments
            )
        }
        || Comment <- DirectComments
    ].

find_post(PostId, Posts) ->
    case lists:search(
        fun(Post) -> maps:get(id, Post) =:= PostId end,
        Posts
    ) of
        false -> error;
        {value, Post} -> {ok, Post}
    end.

find_comment(CommentId, Comments) ->
    case lists:search(
        fun(Comment) -> maps:get(id, Comment) =:= CommentId end,
        Comments
    ) of
        false -> error;
        {value, Comment} -> {ok, Comment}
    end.

%% Validation

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
