
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
    get_post_comments/2,
    vote_post/4,
    vote_comment/4,
    get_post_score/2,
    get_comment_score/2,
    get_karma/2
]).

%% Engine lifecycle

start_link() ->
    spawn_link(fun() ->
        loop(#{
            accounts => #{},
            subreddits => #{},
            posts => [],
            next_post_id => 1,
            comments => [],
            next_comment_id => 1,
            votes => #{}
        })
    end).

stop(EnginePid) when is_pid(EnginePid) ->
    EnginePid ! stop,
    ok.

%% Public API

register_account(EnginePid, Username) ->
    request(EnginePid, {register, Username}).

account_count(EnginePid) ->
    request(EnginePid, account_count).

create_subreddit(EnginePid, Username, Name) ->
    request(EnginePid, {create_subreddit, Username, Name}).

join_subreddit(EnginePid, Username, Name) ->
    request(EnginePid, {join_subreddit, Username, Name}).

leave_subreddit(EnginePid, Username, Name) ->
    request(EnginePid, {leave_subreddit, Username, Name}).

subreddit_info(EnginePid, Name) ->
    request(EnginePid, {subreddit_info, Name}).

create_post(EnginePid, Username, Subreddit, Content) ->
    request(EnginePid, {create_post, Username, Subreddit, Content}).

get_feed(EnginePid, Username) ->
    request(EnginePid, {get_feed, Username}).

add_comment(EnginePid, Username, PostId, ParentId, Content) ->
    request(EnginePid, {add_comment, Username, PostId, ParentId, Content}).

get_post_comments(EnginePid, PostId) ->
    request(EnginePid, {get_post_comments, PostId}).

vote_post(EnginePid, Username, PostId, Vote) ->
    request(EnginePid, {vote_post, Username, PostId, Vote}).

vote_comment(EnginePid, Username, CommentId, Vote) ->
    request(EnginePid, {vote_comment, Username, CommentId, Vote}).

get_post_score(EnginePid, PostId) ->
    request(EnginePid, {get_post_score, PostId}).

get_comment_score(EnginePid, CommentId) ->
    request(EnginePid, {get_comment_score, CommentId}).

get_karma(EnginePid, Username) ->
    request(EnginePid, {get_karma, Username}).

request(EnginePid, Request) ->
    Ref = make_ref(),
    EnginePid ! {request, self(), Ref, Request},
    receive
        {reply, Ref, Result} ->
            Result
    after 5000 ->
        {error, timeout}
    end.

%% Main engine process

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

        {request, From, Ref, {create_subreddit, Username, Name}} ->
            {Result, NewState} =
                create_subreddit_state(Username, Name, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {join_subreddit, Username, Name}} ->
            {Result, NewState} =
                join_subreddit_state(Username, Name, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {leave_subreddit, Username, Name}} ->
            {Result, NewState} =
                leave_subreddit_state(Username, Name, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {subreddit_info, Name}} ->
            Result = get_subreddit_info(Name, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref, {create_post, Username, Name, Content}} ->
            {Result, NewState} =
                create_post_state(Username, Name, Content, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_feed, Username}} ->
            Result = get_user_feed(Username, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref,
         {add_comment, Username, PostId, ParentId, Content}} ->
            {Result, NewState} =
                add_comment_state(
                    Username, PostId, ParentId, Content, State
                ),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_post_comments, PostId}} ->
            Result = get_post_comments_state(PostId, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref, {vote_post, Username, PostId, Vote}} ->
            {Result, NewState} =
                vote_state(post, Username, PostId, Vote, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {vote_comment, Username, CommentId, Vote}} ->
            {Result, NewState} =
                vote_state(comment, Username, CommentId, Vote, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_post_score, PostId}} ->
            Result = target_score(post, PostId, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref, {get_comment_score, CommentId}} ->
            Result = target_score(comment, CommentId, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref, {get_karma, Username}} ->
            Result = account_karma(Username, State),
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
                    UpdatedAccounts = maps:put(
                        Username, Account, Accounts
                    ),
                    {{ok, registered},
                     State#{accounts := UpdatedAccounts}}
            end;
        Error ->
            {Error, State}
    end.

%% Subreddit management

create_subreddit_state(Username, Name, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case {maps:is_key(Username, Accounts), validate_name(Name)} of
        {false, _} ->
            {{error, account_not_found}, State};
        {true, {error, Reason}} ->
            {{error, Reason}, State};
        {true, ok} ->
            case maps:is_key(Name, Subreddits) of
                true ->
                    {{error, subreddit_exists}, State};
                false ->
                    Subreddit = #{
                        name => Name,
                        creator => Username,
                        members => #{Username => true}
                    },
                    Updated = maps:put(Name, Subreddit, Subreddits),
                    {{ok, subreddit_created},
                     State#{subreddits := Updated}}
            end
    end.

join_subreddit_state(Username, Name, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case maps:find(Name, Subreddits) of
                error ->
                    {{error, subreddit_not_found}, State};
                {ok, Subreddit} ->
                    Members = maps:get(members, Subreddit),
                    case maps:is_key(Username, Members) of
                        true ->
                            {{error, already_member}, State};
                        false ->
                            UpdatedMembers = maps:put(
                                Username, true, Members
                            ),
                            UpdatedSubreddit =
                                Subreddit#{members := UpdatedMembers},
                            UpdatedSubreddits = maps:put(
                                Name, UpdatedSubreddit, Subreddits
                            ),
                            {{ok, joined},
                             State#{subreddits := UpdatedSubreddits}}
                    end
            end
    end.

leave_subreddit_state(Username, Name, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case maps:find(Name, Subreddits) of
                error ->
                    {{error, subreddit_not_found}, State};
                {ok, Subreddit} ->
                    Members = maps:get(members, Subreddit),
                    case maps:is_key(Username, Members) of
                        false ->
                            {{error, not_member}, State};
                        true ->
                            UpdatedMembers = maps:remove(
                                Username, Members
                            ),
                            UpdatedSubreddit =
                                Subreddit#{members := UpdatedMembers},
                            UpdatedSubreddits = maps:put(
                                Name, UpdatedSubreddit, Subreddits
                            ),
                            {{ok, left},
                             State#{subreddits := UpdatedSubreddits}}
                    end
            end
    end.

get_subreddit_info(Name, State) ->
    Subreddits = maps:get(subreddits, State),
    case maps:find(Name, Subreddits) of
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

%% Post creation and feeds

create_post_state(Username, Name, Content, State) ->
    Accounts = maps:get(accounts, State),
    Subreddits = maps:get(subreddits, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case maps:find(Name, Subreddits) of
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
                                        subreddit => Name,
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
            Joined = [
                Name
                || {Name, Subreddit} <- maps:to_list(Subreddits),
                   maps:is_key(
                       Username, maps:get(members, Subreddit)
                   )
            ],
            Feed = [
                Post
                || Post <- maps:get(posts, State),
                   lists:member(
                       maps:get(subreddit, Post), Joined
                   )
            ],
            {ok, Feed}
    end.

%% Comment creation and hierarchical replies

add_comment_state(Username, PostId, ParentId, Content, State) ->
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
                    Subreddit = maps:get(
                        SubredditName, maps:get(subreddits, State)
                    ),
                    Members = maps:get(members, Subreddit),
                    case maps:is_key(Username, Members) of
                        false ->
                            {{error, not_member}, State};
                        true ->
                            case validate_content(Content) of
                                {error, Reason} ->
                                    {{error, Reason}, State};
                                ok ->
                                    store_comment(
                                        Username, PostId, ParentId,
                                        Content, Comments, State
                                    )
                            end
                    end
            end
    end.

store_comment(Username, PostId, ParentId, Content, Comments, State) ->
    case validate_parent_comment(PostId, ParentId, Comments) of
        ok ->
            CommentId = maps:get(next_comment_id, State),
            Comment = #{
                id => CommentId,
                post_id => PostId,
                parent_id => ParentId,
                author => Username,
                content => Content,
                timestamp => erlang:system_time(second)
            },
            NewState = State#{
                comments := [Comment | Comments],
                next_comment_id := CommentId + 1
            },
            {{ok, CommentId}, NewState};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

validate_parent_comment(_PostId, none, _Comments) ->
    ok;
validate_parent_comment(PostId, ParentId, Comments)
        when is_integer(ParentId) ->
    case find_comment(ParentId, Comments) of
        error ->
            {error, parent_comment_not_found};
        {ok, Parent} ->
            case maps:get(post_id, Parent) =:= PostId of
                true -> ok;
                false -> {error, parent_comment_wrong_post}
            end
    end;
validate_parent_comment(_PostId, _ParentId, _Comments) ->
    {error, invalid_parent_comment_id}.

get_post_comments_state(PostId, State) ->
    case find_post(PostId, maps:get(posts, State)) of
        error ->
            {error, post_not_found};
        {ok, _Post} ->
            Comments = maps:get(comments, State),
            {ok, build_comment_tree(PostId, none, Comments)}
    end.

build_comment_tree(PostId, ParentId, Comments) ->
    Direct = lists:sort(
        fun(A, B) -> maps:get(id, A) < maps:get(id, B) end,
        [
            C
            || C <- Comments,
               maps:get(post_id, C) =:= PostId,
               maps:get(parent_id, C) =:= ParentId
        ]
    ),
    [
        C#{
            replies => build_comment_tree(
                PostId, maps:get(id, C), Comments
            )
        }
        || C <- Direct
    ].

%% Voting

vote_state(Type, Username, TargetId, Vote, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case validate_vote(Vote) of
                false ->
                    {{error, invalid_vote}, State};
                true ->
                    case find_target(Type, TargetId, State) of
                        error ->
                            {{error, target_not_found}, State};
                        {ok, Target} ->
                            Author = maps:get(author, Target),
                            case Author =:= Username of
                                true ->
                                    {{error, self_vote}, State};
                                false ->
                                    store_vote(
                                        Type, TargetId, Username,
                                        Vote, State
                                    )
                            end
                    end
            end
    end.

validate_vote(upvote) -> true;
validate_vote(downvote) -> true;
validate_vote(_) -> false.

find_target(post, Id, State) ->
    find_post(Id, maps:get(posts, State));
find_target(comment, Id, State) ->
    find_comment(Id, maps:get(comments, State)).

store_vote(Type, TargetId, Username, Vote, State) ->
    Votes = maps:get(votes, State),
    Key = {Type, TargetId, Username},
    Previous = maps:get(Key, Votes, none),

    case Previous =:= Vote of
        true ->
            {{ok, unchanged}, State};
        false ->
            UpdatedVotes = maps:put(Key, Vote, Votes),
            NewState = State#{votes := UpdatedVotes},
            {{ok, Vote}, NewState}
    end.

target_score(Type, TargetId, State) ->
    case find_target(Type, TargetId, State) of
        error ->
            {error, target_not_found};
        {ok, _Target} ->
            {Upvotes, Downvotes} = count_votes(Type, TargetId, State),
            {ok, #{
                upvotes => Upvotes,
                downvotes => Downvotes,
                score => Upvotes - Downvotes
            }}
    end.

count_votes(Type, TargetId, State) ->
    Votes = maps:get(votes, State),
    VoteList = [
        Vote
        || {{VoteType, VoteTargetId, _Username}, Vote} <-
            maps:to_list(Votes),
           VoteType =:= Type,
           VoteTargetId =:= TargetId
    ],
    Upvotes = length([V || V <- VoteList, V =:= upvote]),
    Downvotes = length([V || V <- VoteList, V =:= downvote]),
    {Upvotes, Downvotes}.

account_karma(Username, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            PostIds = [
                maps:get(id, P)
                || P <- maps:get(posts, State),
                   maps:get(author, P) =:= Username
            ],
            CommentIds = [
                maps:get(id, C)
                || C <- maps:get(comments, State),
                   maps:get(author, C) =:= Username
            ],
            PostKarma = lists:sum([
                score_value(post, Id, State)
                || Id <- PostIds
            ]),
            CommentKarma = lists:sum([
                score_value(comment, Id, State)
                || Id <- CommentIds
            ]),
            {ok, #{
                username => Username,
                post_karma => PostKarma,
                comment_karma => CommentKarma,
                total_karma => PostKarma + CommentKarma
            }}
    end.

score_value(Type, TargetId, State) ->
    {Upvotes, Downvotes} = count_votes(Type, TargetId, State),
    Upvotes - Downvotes.

%% Lookup helpers

find_post(PostId, Posts) ->
    case lists:search(
        fun(P) -> maps:get(id, P) =:= PostId end,
        Posts
    ) of
        false -> error;
        {value, Post} -> {ok, Post}
    end.

find_comment(CommentId, Comments) ->
    case lists:search(
        fun(C) -> maps:get(id, C) =:= CommentId end,
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
