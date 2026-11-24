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
    repost/3,
    get_user_reposts/2,
    get_feed/2,
    add_comment/5,
    get_post_comments/2,
    vote_post/4,
    vote_comment/4,
    get_post_score/2,
    get_comment_score/2,
    get_karma/2,
    send_message/4,
    get_inbox/2,
    get_sent_messages/2,
    get_conversation/3,
    reply_to_message/4
]).

%% Engine lifecycle

start_link() ->
    spawn_link(fun() ->
        loop(#{
            accounts => #{},
            subreddits => #{},
            user_subreddits => #{},
            posts => [],
            posts_by_id => #{},
            posts_by_subreddit => #{},
            posts_by_author => #{},
            repost_keys => #{},
            next_post_id => 1,
            comments => [],
            comments_by_id => #{},
            comments_by_post => #{},
            comment_children => #{},
            comments_by_author => #{},
            next_comment_id => 1,
            votes => #{},
            vote_counts => #{},
            messages => [],
            messages_by_id => #{},
            inbox_by_user => #{},
            sent_by_user => #{},
            conversations => #{},
            next_message_id => 1
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

repost(EnginePid, Username, PostId) ->
    request(EnginePid, {repost, Username, PostId}).

get_user_reposts(EnginePid, Username) ->
    request(EnginePid, {get_user_reposts, Username}).

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

send_message(EnginePid, Sender, Recipient, Content) ->
    request(EnginePid, {send_message, Sender, Recipient, Content}).

get_inbox(EnginePid, Username) ->
    request(EnginePid, {get_inbox, Username}).

get_sent_messages(EnginePid, Username) ->
    request(EnginePid, {get_sent_messages, Username}).

get_conversation(EnginePid, Username, OtherUsername) ->
    request(EnginePid, {get_conversation, Username, OtherUsername}).

reply_to_message(EnginePid, Sender, ParentMessageId, Content) ->
    request(
        EnginePid,
        {reply_to_message, Sender, ParentMessageId, Content}
    ).

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

        {request, From, Ref, {repost, Username, PostId}} ->
            {Result, NewState} = repost_state(Username, PostId, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_user_reposts, Username}} ->
            Result = get_user_reposts_state(Username, State),
            reply_and_continue(From, Ref, Result, State);

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

        {request, From, Ref,
         {send_message, Sender, Recipient, Content}} ->
            {Result, NewState} =
                send_message_state(Sender, Recipient, Content, State),
            reply_and_continue(From, Ref, Result, NewState);

        {request, From, Ref, {get_inbox, Username}} ->
            Result = get_user_messages(inbox, Username, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref, {get_sent_messages, Username}} ->
            Result = get_user_messages(sent, Username, State),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref,
         {get_conversation, Username, OtherUsername}} ->
            Result = get_conversation_state(
                Username, OtherUsername, State
            ),
            reply_and_continue(From, Ref, Result, State);

        {request, From, Ref,
         {reply_to_message, Sender, ParentMessageId, Content}} ->
            {Result, NewState} = reply_to_message_state(
                Sender, ParentMessageId, Content, State
            ),
            reply_and_continue(From, Ref, Result, NewState);

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
                    UserSubreddits = maps:get(user_subreddits, State),
                    UserMemberships = maps:get(Username, UserSubreddits, #{}),
                    UpdatedUserSubreddits = maps:put(
                        Username,
                        maps:put(Name, true, UserMemberships),
                        UserSubreddits
                    ),
                    {{ok, subreddit_created}, State#{
                        subreddits := Updated,
                        user_subreddits := UpdatedUserSubreddits
                    }}
            end
    end.

%% Continue: subreddit management

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
                            UserSubreddits = maps:get(user_subreddits, State),
                            UserMemberships = maps:get(
                                Username, UserSubreddits, #{}
                            ),
                            UpdatedUserSubreddits = maps:put(
                                Username,
                                maps:put(Name, true, UserMemberships),
                                UserSubreddits
                            ),
                            {{ok, joined}, State#{
                                subreddits := UpdatedSubreddits,
                                user_subreddits := UpdatedUserSubreddits
                            }}
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
                            UserSubreddits = maps:get(user_subreddits, State),
                            UserMemberships = maps:get(
                                Username, UserSubreddits, #{}
                            ),
                            UpdatedUserSubreddits = maps:put(
                                Username,
                                maps:remove(Name, UserMemberships),
                                UserSubreddits
                            ),
                            {{ok, left}, State#{
                                subreddits := UpdatedSubreddits,
                                user_subreddits := UpdatedUserSubreddits
                            }}
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
                                    NewState = index_post(Post, State),
                                    {{ok, PostId}, NewState#{
                                        next_post_id := PostId + 1
                                    }}
                            end
                    end
            end
    end.

%% Reposting
%% A repost is represented as a new post authored by the reposter.
%% It retains the original post ID and author for attribution. Because it
%% is stored in the normal posts collection, feeds, comments, voting, and
%% karma continue to use the existing post mechanisms.

repost_state(Username, PostId, State) ->
    Accounts = maps:get(accounts, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case find_post(PostId, State) of
                error ->
                    {{error, post_not_found}, State};
                {ok, OriginalPost} ->
                    SubredditName = maps:get(subreddit, OriginalPost),
                    Subreddits = maps:get(subreddits, State),
                    Subreddit = maps:get(SubredditName, Subreddits),
                    Members = maps:get(members, Subreddit),

                    case maps:is_key(Username, Members) of
                        false ->
                            {{error, not_member}, State};
                        true ->
                            RepostKeys = maps:get(repost_keys, State),
                            AlreadyReposted = maps:is_key(
                                {Username, PostId}, RepostKeys
                            ),

                            case AlreadyReposted of
                                true ->
                                    {{error, already_reposted}, State};
                                false ->
                                    RepostId = maps:get(next_post_id, State),
                                    Repost = #{
                                        id => RepostId,
                                        author => Username,
                                        subreddit => SubredditName,
                                        content => maps:get(content, OriginalPost),
                                        timestamp => erlang:system_time(second),
                                        is_repost => true,
                                        original_post_id => PostId,
                                        original_author => maps:get(author, OriginalPost)
                                    },
                                    IndexedState = index_post(Repost, State),
                                    UpdatedRepostKeys = maps:put(
                                        {Username, PostId}, true,
                                        maps:get(repost_keys, IndexedState)
                                    ),
                                    NewState = IndexedState#{
                                        next_post_id := RepostId + 1,
                                        repost_keys := UpdatedRepostKeys
                                    },
                                    {{ok, RepostId}, NewState}
                            end
                    end
            end
    end.

get_user_reposts_state(Username, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            AuthorPostIds = maps:get(
                Username, maps:get(posts_by_author, State), []
            ),
            PostsById = maps:get(posts_by_id, State),
            Reposts = [
                maps:get(Id, PostsById)
                || Id <- lists:reverse(AuthorPostIds),
                   maps:get(is_repost, maps:get(Id, PostsById), false)
            ],
            {ok, Reposts}
    end.

get_user_feed(Username, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            Joined = maps:keys(maps:get(
                Username, maps:get(user_subreddits, State), #{}
            )),
            PostsBySubreddit = maps:get(posts_by_subreddit, State),
            PostsById = maps:get(posts_by_id, State),
            OrderedIds = merge_subreddit_post_ids(
                Joined, PostsBySubreddit
            ),
            Feed = [maps:get(Id, PostsById) || Id <- OrderedIds],
            {ok, Feed}
    end.

%% Each subreddit index is maintained newest-first: post IDs are globally
%% increasing and index_id/3 prepends each new ID. Merge those sorted lists
%% with a min-priority queue over negative IDs. This avoids sorting the full
%% combined feed for every user.
%% Complexity: O(P_u log S), with O(S) queue storage.
merge_subreddit_post_ids(JoinedSubreddits, PostsBySubreddit) ->
    Queue = lists:foldl(
        fun(Subreddit, Accumulator) ->
            case maps:get(Subreddit, PostsBySubreddit, []) of
                [PostId | RemainingIds] ->
                    gb_sets:add_element(
                        {-PostId, Subreddit, RemainingIds}, Accumulator
                    );
                [] ->
                    Accumulator
            end
        end,
        gb_sets:empty(),
        JoinedSubreddits
    ),
    merge_post_queue(Queue, []).

merge_post_queue(Queue, Accumulator) ->
    case gb_sets:is_empty(Queue) of
        true ->
            lists:reverse(Accumulator);
        false ->
            {NegativePostId, Subreddit, RemainingIds} =
                gb_sets:smallest(Queue),
            Queue1 = gb_sets:delete(
                {NegativePostId, Subreddit, RemainingIds}, Queue
            ),
            Queue2 = case RemainingIds of
                [NextPostId | Tail] ->
                    gb_sets:add_element(
                        {-NextPostId, Subreddit, Tail}, Queue1
                    );
                [] ->
                    Queue1
            end,
            merge_post_queue(
                Queue2, [-NegativePostId | Accumulator]
            )
    end.

%% Comment creation and hierarchical replies

add_comment_state(Username, PostId, ParentId, Content, State) ->
    Accounts = maps:get(accounts, State),

    case maps:is_key(Username, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case find_post(PostId, State) of
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
                                        Content, State
                                    )
                            end
                    end
            end
    end.

store_comment(Username, PostId, ParentId, Content, State) ->
    case validate_parent_comment(PostId, ParentId, State) of
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
            NewState = index_comment(Comment, State),
            {{ok, CommentId}, NewState#{
                next_comment_id := CommentId + 1
            }};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

validate_parent_comment(_PostId, none, _State) ->
    ok;
validate_parent_comment(PostId, ParentId, State)
        when is_integer(ParentId) ->
    case find_comment(ParentId, State) of
        error ->
            {error, parent_comment_not_found};
        {ok, Parent} ->
            case maps:get(post_id, Parent) =:= PostId of
                true -> ok;
                false -> {error, parent_comment_wrong_post}
            end
    end;
validate_parent_comment(_PostId, _ParentId, _State) ->
    {error, invalid_parent_comment_id}.

get_post_comments_state(PostId, State) ->
    case find_post(PostId, State) of
        error ->
            {error, post_not_found};
        {ok, _Post} ->
            {ok, build_comment_tree(PostId, none, State)}
    end.

build_comment_tree(PostId, ParentId, State) ->
    ChildIndex = maps:get(comment_children, State),
    CommentIds = lists:reverse(maps:get({PostId, ParentId}, ChildIndex, [])),
    CommentsById = maps:get(comments_by_id, State),
    [
        begin
            Comment = maps:get(CommentId, CommentsById),
            Comment#{
                replies => build_comment_tree(
                    PostId, CommentId, State
                )
            }
        end
        || CommentId <- CommentIds
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
    find_post(Id, State);
find_target(comment, Id, State) ->
    find_comment(Id, State).

store_vote(Type, TargetId, Username, Vote, State) ->
    Votes = maps:get(votes, State),
    Key = {Type, TargetId, Username},
    Previous = maps:get(Key, Votes, none),

    case Previous =:= Vote of
        true ->
            {{ok, unchanged}, State};
        false ->
            UpdatedVotes = maps:put(Key, Vote, Votes),
            VoteCounts = maps:get(vote_counts, State),
            CurrentCounts = maps:get({Type, TargetId}, VoteCounts, {0, 0}),
            UpdatedCounts = adjust_vote_counts(CurrentCounts, Previous, Vote),
            NewVoteCounts = maps:put(
                {Type, TargetId}, UpdatedCounts, VoteCounts
            ),
            NewState = State#{
                votes := UpdatedVotes,
                vote_counts := NewVoteCounts
            },
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

adjust_vote_counts({Upvotes, Downvotes}, none, upvote) ->
    {Upvotes + 1, Downvotes};
adjust_vote_counts({Upvotes, Downvotes}, none, downvote) ->
    {Upvotes, Downvotes + 1};
adjust_vote_counts({Upvotes, Downvotes}, upvote, downvote) ->
    {Upvotes - 1, Downvotes + 1};
adjust_vote_counts({Upvotes, Downvotes}, downvote, upvote) ->
    {Upvotes + 1, Downvotes - 1}.

count_votes(Type, TargetId, State) ->
    maps:get({Type, TargetId}, maps:get(vote_counts, State), {0, 0}).

account_karma(Username, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            PostIds = maps:get(
                Username, maps:get(posts_by_author, State), []
            ),
            CommentIds = maps:get(
                Username, maps:get(comments_by_author, State), []
            ),
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

%% Direct messages and threaded replies

send_message_state(Sender, Recipient, Content, State) ->
    Accounts = maps:get(accounts, State),
    case {maps:is_key(Sender, Accounts),
          maps:is_key(Recipient, Accounts)} of
        {false, _} ->
            {{error, sender_not_found}, State};
        {true, false} ->
            {{error, recipient_not_found}, State};
        {true, true} when Sender =:= Recipient ->
            {{error, cannot_message_self}, State};
        {true, true} ->
            case validate_content(Content) of
                {error, Reason} ->
                    {{error, Reason}, State};
                ok ->
                    store_message(Sender, Recipient, none, Content, State)
            end
    end.

store_message(Sender, Recipient, ParentId, Content, State) ->
    MessageId = maps:get(next_message_id, State),
    Message = #{
        id => MessageId,
        sender => Sender,
        recipient => Recipient,
        content => Content,
        parent_id => ParentId,
        timestamp => erlang:system_time(millisecond)
    },
    MessagesById = maps:put(
        MessageId, Message, maps:get(messages_by_id, State)
    ),
    Inbox = maps:get(inbox_by_user, State),
    Sent = maps:get(sent_by_user, State),
    Conversations = maps:get(conversations, State),
    Pair = conversation_key(Sender, Recipient),
    NewState = State#{
        messages := [Message | maps:get(messages, State)],
        messages_by_id := MessagesById,
        inbox_by_user := index_id(Recipient, MessageId, Inbox),
        sent_by_user := index_id(Sender, MessageId, Sent),
        conversations := index_id(Pair, MessageId, Conversations),
        next_message_id := MessageId + 1
    },
    {{ok, MessageId}, NewState}.

get_user_messages(Type, Username, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Username, Accounts) of
        false ->
            {error, account_not_found};
        true ->
            Index = case Type of
                inbox -> maps:get(inbox_by_user, State);
                sent -> maps:get(sent_by_user, State)
            end,
            MessageIds = lists:reverse(maps:get(Username, Index, [])),
            MessagesById = maps:get(messages_by_id, State),
            {ok, [maps:get(Id, MessagesById) || Id <- MessageIds]}
    end.

get_conversation_state(Username, OtherUsername, State) ->
    Accounts = maps:get(accounts, State),
    case {maps:is_key(Username, Accounts),
          maps:is_key(OtherUsername, Accounts)} of
        {false, _} ->
            {error, account_not_found};
        {true, false} ->
            {error, account_not_found};
        {true, true} when Username =:= OtherUsername ->
            {error, invalid_conversation};
        {true, true} ->
            Pair = conversation_key(Username, OtherUsername),
            MessageIds = lists:reverse(maps:get(
                Pair, maps:get(conversations, State), []
            )),
            MessagesById = maps:get(messages_by_id, State),
            {ok, [maps:get(Id, MessagesById) || Id <- MessageIds]}
    end.

reply_to_message_state(Sender, ParentMessageId, Content, State) ->
    Accounts = maps:get(accounts, State),
    case maps:is_key(Sender, Accounts) of
        false ->
            {{error, account_not_found}, State};
        true ->
            case find_message(ParentMessageId, State) of
                error ->
                    {{error, message_not_found}, State};
                {ok, Parent} ->
                    ParentSender = maps:get(sender, Parent),
                    ParentRecipient = maps:get(recipient, Parent),
                    case reply_recipient(
                        Sender, ParentSender, ParentRecipient
                    ) of
                        error ->
                            {{error, not_conversation_participant}, State};
                        {ok, Recipient} ->
                            case validate_content(Content) of
                                {error, Reason} ->
                                    {{error, Reason}, State};
                                ok ->
                                    store_message(
                                        Sender, Recipient, ParentMessageId,
                                        Content, State
                                    )
                            end
                    end
            end
    end.

reply_recipient(Sender, OriginalSender, OriginalRecipient)
        when Sender =:= OriginalSender ->
    {ok, OriginalRecipient};
reply_recipient(Sender, OriginalSender, OriginalRecipient)
        when Sender =:= OriginalRecipient ->
    {ok, OriginalSender};
reply_recipient(_Sender, _OriginalSender, _OriginalRecipient) ->
    error.

find_message(MessageId, State) ->
    case maps:find(MessageId, maps:get(messages_by_id, State)) of
        error -> error;
        {ok, Message} -> {ok, Message}
    end.

conversation_key(User1, User2) when User1 =< User2 ->
    {User1, User2};
conversation_key(User1, User2) ->
    {User2, User1}.

index_id(Key, Id, Index) ->
    maps:put(Key, [Id | maps:get(Key, Index, [])], Index).

index_post(Post, State) ->
    PostId = maps:get(id, Post),
    Subreddit = maps:get(subreddit, Post),
    Author = maps:get(author, Post),
    PostsById = maps:put(
        PostId, Post, maps:get(posts_by_id, State)
    ),
    NewPostsBySubreddit = index_id(
        Subreddit, PostId, maps:get(posts_by_subreddit, State)
    ),
    NewPostsByAuthor = index_id(
        Author, PostId, maps:get(posts_by_author, State)
    ),
    State#{
        posts := [Post | maps:get(posts, State)],
        posts_by_id := PostsById,
        posts_by_subreddit := NewPostsBySubreddit,
        posts_by_author := NewPostsByAuthor
    }.

index_comment(Comment, State) ->
    CommentId = maps:get(id, Comment),
    PostId = maps:get(post_id, Comment),
    ParentId = maps:get(parent_id, Comment),
    Author = maps:get(author, Comment),
    CommentsById = maps:put(
        CommentId, Comment, maps:get(comments_by_id, State)
    ),
    CommentsByPost = index_id(
        PostId, CommentId, maps:get(comments_by_post, State)
    ),
    CommentChildren = index_id(
        {PostId, ParentId}, CommentId,
        maps:get(comment_children, State)
    ),
    CommentsByAuthor = index_id(
        Author, CommentId, maps:get(comments_by_author, State)
    ),
    State#{
        comments := [Comment | maps:get(comments, State)],
        comments_by_id := CommentsById,
        comments_by_post := CommentsByPost,
        comment_children := CommentChildren,
        comments_by_author := CommentsByAuthor
    }.

find_post(PostId, State) ->
    case maps:find(PostId, maps:get(posts_by_id, State)) of
        error -> error;
        {ok, Post} -> {ok, Post}
    end.

find_comment(CommentId, State) ->
    case maps:find(CommentId, maps:get(comments_by_id, State)) of
        error -> error;
        {ok, Comment} -> {ok, Comment}
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