
-module(reddit_tests).

-include_lib("eunit/include/eunit.hrl").

%% Milestone 1: accounts and clients

engine_start_test() ->
    Engine = reddit_engine:start_link(),
    try
        ?assert(is_pid(Engine)),
        ?assertEqual({ok, 0}, reddit_engine:account_count(Engine))
    after
        reddit_engine:stop(Engine)
    end.

single_registration_test() ->
    with_engine_client(fun(Engine, Client) ->
        ?assertEqual(
            {ok, registered},
            reddit_client:register(Client, "alice")
        ),
        ?assertEqual({ok, 1}, reddit_engine:account_count(Engine))
    end).

duplicate_username_test() ->
    Engine = reddit_engine:start_link(),
    Client1 = reddit_client:start_link(Engine),
    Client2 = reddit_client:start_link(Engine),
    try
        ?assertEqual(
            {ok, registered},
            reddit_client:register(Client1, "alice")
        ),
        ?assertEqual(
            {error, username_taken},
            reddit_client:register(Client2, "alice")
        ),
        ?assertEqual({ok, 1}, reddit_engine:account_count(Engine))
    after
        reddit_client:stop(Client1),
        reddit_client:stop(Client2),
        reddit_engine:stop(Engine)
    end.

invalid_username_test() ->
    with_engine_client(fun(Engine, Client) ->
        ?assertEqual(
            {error, invalid_name},
            reddit_client:register(Client, "")
        ),
        ?assertEqual(
            {error, invalid_name},
            reddit_client:register(Client, "   ")
        ),
        ?assertEqual({ok, 0}, reddit_engine:account_count(Engine))
    end).

concurrent_registration_test() ->
    Engine = reddit_engine:start_link(),
    Clients = start_clients(20, Engine),
    try
        Parent = self(),
        [
            spawn(fun() ->
                Username = "user_" ++ integer_to_list(Index),
                Result = reddit_client:register(Client, Username),
                Parent ! {registration_result, Result}
            end)
            || {Client, Index} <- lists:zip(Clients, lists:seq(1, 20))
        ],

        Results = collect_results(20, registration_result, []),
        ?assertEqual(20, count_successes(Results)),
        ?assertEqual({ok, 20}, reddit_engine:account_count(Engine))
    after
        stop_clients(Clients),
        reddit_engine:stop(Engine)
    end.

simulator_test() ->
    Summary = reddit_simulator:run(25),
    ?assertEqual(25, maps:get(requested_users, Summary)),
    ?assertEqual(25, maps:get(successful_registrations, Summary)),
    ?assertEqual(0, maps:get(failed_registrations, Summary)),
    ?assertEqual({ok, 25}, maps:get(engine_account_count, Summary)).

%% Client online/offline lifecycle tests

client_starts_connected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual({ok, true}, reddit_client:is_connected(Client))
    end).

client_disconnect_rejects_operations_test() ->
    with_engine_client(fun(Engine, Client) ->
        register_user(Client, "alice"),
        ?assertEqual({ok, disconnected}, reddit_client:disconnect(Client)),
        ?assertEqual({ok, false}, reddit_client:is_connected(Client)),
        ?assertEqual({error, offline}, reddit_client:get_feed(Client, "alice")),
        ?assertEqual({ok, 1}, reddit_engine:account_count(Engine))
    end).

client_reconnect_restores_operations_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:disconnect(Client),
        ?assertEqual({ok, connected}, reddit_client:connect(Client)),
        ?assertEqual({ok, true}, reddit_client:is_connected(Client)),
        ?assertMatch({ok, _}, reddit_client:get_feed(Client, "alice"))
    end).

client_repeated_connection_transitions_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual({ok, already_connected}, reddit_client:connect(Client)),
        ?assertEqual({ok, disconnected}, reddit_client:disconnect(Client)),
        ?assertEqual({ok, already_disconnected}, reddit_client:disconnect(Client)),
        ?assertEqual({ok, connected}, reddit_client:connect(Client)),
        ?assertEqual({ok, true}, reddit_client:is_connected(Client))
    end).

lifecycle_simulator_test() ->
    Summary = reddit_simulator:run_lifecycle(3, #{
        duration_ms => 180,
        online_ms => 30,
        offline_ms => 30,
        operation_interval_ms => 5
    }),
    ?assertEqual(3, maps:get(requested_users, Summary)),
    ?assertEqual({ok, 3}, maps:get(engine_account_count, Summary)),
    ?assert(maps:get(connection_attempts, Summary) > 0),
    ?assert(maps:get(successful_connections, Summary) > 0),
    ?assert(maps:get(disconnections, Summary) > 0),
    ?assert(maps:get(online_time_ms, Summary) > 0),
    ?assert(maps:get(offline_time_ms, Summary) > 0),
    ?assert(maps:get(successful, Summary) > 0),
    ?assert(maps:get(offline_rejected, Summary) > 0),
    ?assertEqual(
        maps:get(attempted, Summary),
        maps:get(successful, Summary)
        + maps:get(offline_rejected, Summary)
        + maps:get(failed, Summary)
    ).

%% Milestone 2: subreddit management

create_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        ?assertEqual(
            {ok, subreddit_created},
            reddit_client:create_subreddit(Client, "alice", "erlang")
        ),

        {ok, Info} = reddit_client:subreddit_info(Client, "erlang"),
        ?assertEqual("alice", maps:get(creator, Info)),
        ?assertEqual(1, maps:get(member_count, Info)),
        ?assert(lists:member("alice", maps:get(members, Info)))
    end).

duplicate_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        ?assertEqual(
            {error, subreddit_exists},
            reddit_client:create_subreddit(Client, "alice", "erlang")
        )
    end).

join_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        ?assertEqual(
            {ok, joined},
            reddit_client:join_subreddit(Client, "bob", "erlang")
        ),

        {ok, Info} = reddit_client:subreddit_info(Client, "erlang"),
        ?assertEqual(2, maps:get(member_count, Info)),
        ?assert(lists:member("bob", maps:get(members, Info)))
    end).

duplicate_join_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        ?assertEqual(
            {error, already_member},
            reddit_client:join_subreddit(Client, "alice", "erlang")
        )
    end).

leave_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        ?assertEqual(
            {ok, left},
            reddit_client:leave_subreddit(Client, "bob", "erlang")
        ),

        {ok, Info} = reddit_client:subreddit_info(Client, "erlang"),
        ?assertEqual(1, maps:get(member_count, Info)),
        ?assertNot(lists:member("bob", maps:get(members, Info)))
    end).

leave_nonmember_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        ?assertEqual(
            {error, not_member},
            reddit_client:leave_subreddit(Client, "bob", "erlang")
        )
    end).

join_missing_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        ?assertEqual(
            {error, subreddit_not_found},
            reddit_client:join_subreddit(Client, "alice", "unknown")
        )
    end).

unknown_account_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual(
            {error, account_not_found},
            reddit_client:create_subreddit(Client, "unknown", "erlang")
        ),
        ?assertEqual(
            {error, account_not_found},
            reddit_client:join_subreddit(Client, "unknown", "erlang")
        )
    end).

%% Milestone 3: posts and feeds

create_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        {ok, PostId} = reddit_client:create_post(
            Client,
            "alice",
            "erlang",
            "Learning Erlang actors"
        ),

        ?assertEqual(1, PostId)
    end).

post_appears_in_feed_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        {ok, _PostId} = reddit_client:create_post(
            Client,
            "alice",
            "erlang",
            "First post"
        ),

        {ok, Feed} = reddit_client:get_feed(Client, "alice"),
        ?assertEqual(1, length(Feed)),

        [Post] = Feed,
        ?assertEqual("alice", maps:get(author, Post)),
        ?assertEqual("erlang", maps:get(subreddit, Post)),
        ?assertEqual("First post", maps:get(content, Post))
    end).

joined_member_sees_posts_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        reddit_client:create_post(
            Client, "alice", "erlang", "Hello members"
        ),

        {ok, Feed} = reddit_client:get_feed(Client, "bob"),
        ?assertEqual(1, length(Feed))
    end).

nonmember_cannot_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        ?assertEqual(
            {error, not_member},
            reddit_client:create_post(
                Client, "bob", "erlang", "Unauthorized post"
            )
        )
    end).

post_in_missing_subreddit_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        ?assertEqual(
            {error, subreddit_not_found},
            reddit_client:create_post(
                Client, "alice", "unknown", "Hello"
            )
        )
    end).

empty_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        ?assertEqual(
            {error, empty_content},
            reddit_client:create_post(Client, "alice", "erlang", "")
        ),
        ?assertEqual(
            {error, empty_content},
            reddit_client:create_post(Client, "alice", "erlang", "   ")
        )
    end).

feed_merges_multiple_subreddits_by_newest_post_first_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:create_subreddit(Client, "alice", "programming"),

        {ok, FirstId} = reddit_client:create_post(
            Client, "alice", "erlang", "First"
        ),
        {ok, SecondId} = reddit_client:create_post(
            Client, "alice", "programming", "Second"
        ),
        {ok, ThirdId} = reddit_client:create_post(
            Client, "alice", "erlang", "Third"
        ),

        {ok, Feed} = reddit_client:get_feed(Client, "alice"),
        ?assertEqual(
            [ThirdId, SecondId, FirstId],
            [maps:get(id, Post) || Post <- Feed]
        )
    end).


feed_excludes_unjoined_subreddits_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),

        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:create_subreddit(Client, "bob", "programming"),

        reddit_client:create_post(
            Client, "alice", "erlang", "Erlang post"
        ),
        reddit_client:create_post(
            Client, "bob", "programming", "Programming post"
        ),

        {ok, AliceFeed} = reddit_client:get_feed(Client, "alice"),
        ?assertEqual(1, length(AliceFeed)),
        [AlicePost] = AliceFeed,
        ?assertEqual("erlang", maps:get(subreddit, AlicePost))
    end).

left_subreddit_posts_disappear_from_feed_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),

        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        reddit_client:create_post(
            Client, "alice", "erlang", "A post"
        ),

        {ok, FeedBeforeLeaving} =
            reddit_client:get_feed(Client, "bob"),
        ?assertEqual(1, length(FeedBeforeLeaving)),

        reddit_client:leave_subreddit(Client, "bob", "erlang"),

        {ok, FeedAfterLeaving} =
            reddit_client:get_feed(Client, "bob"),
        ?assertEqual([], FeedAfterLeaving)
    end).

unknown_user_feed_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual(
            {error, account_not_found},
            reddit_client:get_feed(Client, "unknown")
        )
    end).


%% Milestone 4: hierarchical comments and replies

create_top_level_comment_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Learning Erlang"
        ),

        ?assertEqual(
            {ok, 1},
            reddit_client:add_comment(
                Client, "alice", PostId, none, "This is a comment"
            )
        ),

        {ok, Comments} = reddit_client:get_post_comments(Client, PostId),
        ?assertEqual(1, length(Comments)),

        [Comment] = Comments,
        ?assertEqual("alice", maps:get(author, Comment)),
        ?assertEqual("This is a comment", maps:get(content, Comment)),
        ?assertEqual([], maps:get(replies, Comment))
    end).

reply_to_comment_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Learning Erlang"
        ),

        {ok, ParentId} = reddit_client:add_comment(
            Client, "alice", PostId, none, "Parent comment"
        ),

        ?assertEqual(
            {ok, 2},
            reddit_client:add_comment(
                Client, "bob", PostId, ParentId, "Reply to parent"
            )
        ),

        {ok, [Parent]} = reddit_client:get_post_comments(Client, PostId),
        [Reply] = maps:get(replies, Parent),

        ?assertEqual("bob", maps:get(author, Reply)),
        ?assertEqual("Reply to parent", maps:get(content, Reply))
    end).

nested_reply_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Learning Erlang"
        ),

        {ok, FirstId} = reddit_client:add_comment(
            Client, "alice", PostId, none, "First level"
        ),

        {ok, SecondId} = reddit_client:add_comment(
            Client, "bob", PostId, FirstId, "Second level"
        ),

        ?assertEqual(
            {ok, 3},
            reddit_client:add_comment(
                Client, "alice", PostId, SecondId, "Third level"
            )
        ),

        {ok, [First]} = reddit_client:get_post_comments(Client, PostId),
        [Second] = maps:get(replies, First),
        [Third] = maps:get(replies, Second),

        ?assertEqual("First level", maps:get(content, First)),
        ?assertEqual("Second level", maps:get(content, Second)),
        ?assertEqual("Third level", maps:get(content, Third))
    end).

comment_wrong_post_parent_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),

        {ok, Post1} = reddit_client:create_post(
            Client, "alice", "erlang", "Post one"
        ),
        {ok, Post2} = reddit_client:create_post(
            Client, "alice", "erlang", "Post two"
        ),

        {ok, CommentId} = reddit_client:add_comment(
            Client, "alice", Post1, none, "Comment on post one"
        ),

        ?assertEqual(
            {error, parent_comment_wrong_post},
            reddit_client:add_comment(
                Client, "alice", Post2, CommentId, "Invalid reply"
            )
        )
    end).

comment_missing_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),

        ?assertEqual(
            {error, post_not_found},
            reddit_client:add_comment(
                Client, "alice", 999, none, "Comment"
            )
        )
    end).

comment_missing_parent_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Post"
        ),

        ?assertEqual(
            {error, parent_comment_not_found},
            reddit_client:add_comment(
                Client, "alice", PostId, 999, "Reply"
            )
        )
    end).

comment_nonmember_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Post"
        ),

        ?assertEqual(
            {error, not_member},
            reddit_client:add_comment(
                Client, "bob", PostId, none, "Not allowed"
            )
        )
    end).

empty_comment_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, PostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Post"
        ),

        ?assertEqual(
            {error, empty_content},
            reddit_client:add_comment(
                Client, "alice", PostId, none, ""
            )
        )
    end).

get_comments_for_missing_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual(
            {error, post_not_found},
            reddit_client:get_post_comments(Client, 999)
        )
    end).


%% Voting and karma tests


%% Milestone 5: voting and karma

vote_post_upvote_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        ?assertEqual(
            {ok, upvote},
            reddit_client:vote_post(Client, "bob", PostId, upvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 1, downvotes => 0, score => 1}},
            reddit_client:get_post_score(Client, PostId)
        )
    end).

vote_post_downvote_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        ?assertEqual(
            {ok, downvote},
            reddit_client:vote_post(Client, "bob", PostId, downvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 0, downvotes => 1, score => -1}},
            reddit_client:get_post_score(Client, PostId)
        )
    end).

vote_switch_replaces_previous_vote_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        reddit_client:vote_post(Client, "bob", PostId, upvote),
        ?assertEqual(
            {ok, downvote},
            reddit_client:vote_post(Client, "bob", PostId, downvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 0, downvotes => 1, score => -1}},
            reddit_client:get_post_score(Client, PostId)
        )
    end).

repeated_vote_does_not_duplicate_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        reddit_client:vote_post(Client, "bob", PostId, upvote),
        ?assertEqual(
            {ok, unchanged},
            reddit_client:vote_post(Client, "bob", PostId, upvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 1, downvotes => 0, score => 1}},
            reddit_client:get_post_score(Client, PostId)
        )
    end).

self_vote_rejected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        ?assertEqual(
            {error, self_vote},
            reddit_client:vote_post(Client, "alice", PostId, upvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 0, downvotes => 0, score => 0}},
            reddit_client:get_post_score(Client, PostId)
        )
    end).

invalid_vote_rejected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),

        ?assertEqual(
            {error, invalid_vote},
            reddit_client:vote_post(Client, "bob", PostId, neutral)
        )
    end).

vote_comment_and_get_score_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),
        {ok, CommentId} =
            reddit_client:add_comment(
                Client, "alice", PostId, none, "A comment"
            ),

        ?assertEqual(
            {ok, upvote},
            reddit_client:vote_comment(Client, "bob", CommentId, upvote)
        ),
        ?assertEqual(
            {ok, #{upvotes => 1, downvotes => 0, score => 1}},
            reddit_client:get_comment_score(Client, CommentId)
        )
    end).

karma_aggregates_post_and_comment_scores_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        register_user(Client, "carol"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        reddit_client:join_subreddit(Client, "carol", "erlang"),
        {ok, PostId} =
            reddit_client:create_post(Client, "alice", "erlang", "Hello"),
        {ok, CommentId} =
            reddit_client:add_comment(
                Client, "alice", PostId, none, "A comment"
            ),

        reddit_client:vote_post(Client, "bob", PostId, upvote),
        reddit_client:vote_post(Client, "carol", PostId, upvote),
        reddit_client:vote_comment(Client, "bob", CommentId, downvote),

        ?assertEqual(
            {ok, #{
                username => "alice",
                post_karma => 2,
                comment_karma => -1,
                total_karma => 1
            }},
            reddit_client:get_karma(Client, "alice")
        )
    end).

karma_unknown_account_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual(
            {error, account_not_found},
            reddit_client:get_karma(Client, "unknown")
        )
    end).

%% Direct messaging tests

send_message_test() ->
    with_engine_client(fun(_Engine, Client) ->
        ?assertEqual({ok, registered},
            reddit_client:register(Client, "alice")),
        ?assertEqual({ok, registered},
            reddit_client:register(Client, "bob")),

        ?assertEqual({ok, 1},
            reddit_client:send_message(
                Client, "alice", "bob", "Hello Bob"
            )),

        ?assertMatch(
            {ok, [#{id := 1,
                    sender := "alice",
                    recipient := "bob",
                    content := "Hello Bob",
                    parent_id := none}]},
            reddit_client:get_inbox(Client, "bob")
        )
    end).

get_sent_messages_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),

        reddit_client:send_message(
            Client, "alice", "bob", "First message"
        ),
        reddit_client:send_message(
            Client, "alice", "bob", "Second message"
        ),

        ?assertMatch(
            {ok, [#{content := "First message"},
                  #{content := "Second message"}]},
            reddit_client:get_sent_messages(Client, "alice")
        )
    end).

get_conversation_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),

        reddit_client:send_message(
            Client, "alice", "bob", "Hello"
        ),
        reddit_client:send_message(
            Client, "bob", "alice", "Hi"
        ),

        ?assertMatch(
            {ok, [#{sender := "alice"},
                  #{sender := "bob"}]},
            reddit_client:get_conversation(
                Client, "alice", "bob"
            )
        )
    end).

reply_to_message_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),

        {ok, MessageId} = reddit_client:send_message(
            Client, "alice", "bob", "Are you available?"
        ),

        ?assertEqual(
            {ok, 2},
            reddit_client:reply_to_message(
                Client, "bob", MessageId, "Yes, I am."
            )
        ),

        ?assertMatch(
            {ok, [
                #{id := 1, sender := "alice"},
                #{id := 2, sender := "bob",
                  recipient := "alice", parent_id := 1}
            ]},
            reddit_client:get_conversation(
                Client, "alice", "bob"
            )
        )
    end).

reply_to_reply_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),

        {ok, FirstId} = reddit_client:send_message(
            Client, "alice", "bob", "First"
        ),

        {ok, SecondId} = reddit_client:reply_to_message(
            Client, "bob", FirstId, "Second"
        ),

        ?assertEqual(
            {ok, 3},
            reddit_client:reply_to_message(
                Client, "alice", SecondId, "Third"
            )
        ),

        ?assertMatch(
            {ok, [
                #{id := 1, parent_id := none},
                #{id := 2, parent_id := 1},
                #{id := 3, parent_id := 2}
            ]},
            reddit_client:get_conversation(
                Client, "alice", "bob"
            )
        )
    end).

unauthorized_message_reply_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),
        reddit_client:register(Client, "charlie"),

        {ok, MessageId} = reddit_client:send_message(
            Client, "alice", "bob", "Private message"
        ),

        ?assertEqual(
            {error, not_conversation_participant},
            reddit_client:reply_to_message(
                Client, "charlie", MessageId, "Unauthorized reply"
            )
        )
    end).

empty_direct_message_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),
        reddit_client:register(Client, "bob"),

        ?assertEqual(
            {error, empty_content},
            reddit_client:send_message(
                Client, "alice", "bob", "   "
            )
        )
    end).

message_unknown_recipient_test() ->
    with_engine_client(fun(_Engine, Client) ->
        reddit_client:register(Client, "alice"),

        ?assertEqual(
            {error, recipient_not_found},
            reddit_client:send_message(
                Client, "alice", "unknown", "Hello"
            )
        )
    end).

%% Milestone 9: reposts

repost_creates_feed_entry_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        {ok, OriginalPostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Original post"
        ),
        {ok, RepostId} = reddit_client:repost(
            Client, "bob", OriginalPostId
        ),

        ?assertNotEqual(OriginalPostId, RepostId),

        {ok, Feed} = reddit_client:get_feed(Client, "bob"),
        [Repost, Original] = Feed,

        ?assertEqual(RepostId, maps:get(id, Repost)),
        ?assertEqual("bob", maps:get(author, Repost)),
        ?assertEqual("erlang", maps:get(subreddit, Repost)),
        ?assertEqual("Original post", maps:get(content, Repost)),
        ?assertEqual(true, maps:get(is_repost, Repost)),
        ?assertEqual(OriginalPostId, maps:get(original_post_id, Repost)),
        ?assertEqual("alice", maps:get(original_author, Repost)),

        ?assertEqual(OriginalPostId, maps:get(id, Original)),
        ?assertEqual("alice", maps:get(author, Original))
    end).

get_user_reposts_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),

        {ok, OriginalPostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Original post"
        ),
        {ok, RepostId} = reddit_client:repost(
            Client, "bob", OriginalPostId
        ),

        {ok, Reposts} = reddit_client:get_user_reposts(Client, "bob"),
        ?assertEqual(1, length(Reposts)),
        [Repost] = Reposts,
        ?assertEqual(RepostId, maps:get(id, Repost)),
        ?assertEqual(OriginalPostId, maps:get(original_post_id, Repost))
    end).

duplicate_repost_rejected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        reddit_client:join_subreddit(Client, "bob", "erlang"),
        {ok, OriginalPostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Original post"
        ),

        {ok, _RepostId} = reddit_client:repost(
            Client, "bob", OriginalPostId
        ),
        ?assertEqual(
            {error, already_reposted},
            reddit_client:repost(Client, "bob", OriginalPostId)
        ),

        {ok, Reposts} = reddit_client:get_user_reposts(Client, "bob"),
        ?assertEqual(1, length(Reposts))
    end).

repost_missing_post_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        ?assertEqual(
            {error, post_not_found},
            reddit_client:repost(Client, "alice", 999)
        )
    end).

repost_nonmember_rejected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        register_user(Client, "bob"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, OriginalPostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Original post"
        ),

        ?assertEqual(
            {error, not_member},
            reddit_client:repost(Client, "bob", OriginalPostId)
        )
    end).

repost_unknown_user_rejected_test() ->
    with_engine_client(fun(_Engine, Client) ->
        register_user(Client, "alice"),
        reddit_client:create_subreddit(Client, "alice", "erlang"),
        {ok, OriginalPostId} = reddit_client:create_post(
            Client, "alice", "erlang", "Original post"
        ),

        ?assertEqual(
            {error, account_not_found},
            reddit_client:repost(Client, "unknown", OriginalPostId)
        ),
        ?assertEqual(
            {error, account_not_found},
            reddit_client:get_user_reposts(Client, "unknown")
        )
    end).

%% Milestone 7: full simulator workload

full_simulator_workload_test() ->
    Summary = reddit_simulator:run_workload(
        12, #{subreddits => 3}
    ),

    ?assertEqual(
        12,
        maps:get(requested_users, Summary)
    ),

    ?assertEqual(
        {ok, 12},
        maps:get(engine_account_count, Summary)
    ),

    Stats = maps:get(operation_stats, Summary),

    %% Registration
    RegistrationStats = maps:get(registration, Stats),
    ?assertEqual(12, maps:get(attempted, RegistrationStats)),
    ?assertEqual(12, maps:get(successful, RegistrationStats)),
    ?assertEqual(0, maps:get(failed, RegistrationStats)),

    %% Subreddit creation
    SubredditStats = maps:get(subreddit_creation, Stats),
    ?assertEqual(3, maps:get(attempted, SubredditStats)),
    ?assertEqual(3, maps:get(successful, SubredditStats)),
    ?assertEqual(0, maps:get(failed, SubredditStats)),

    %% Subreddit membership
    MembershipStats = maps:get(subreddit_membership, Stats),
    ?assertEqual(11, maps:get(attempted, MembershipStats)),
    ?assertEqual(11, maps:get(successful, MembershipStats)),
    ?assertEqual(0, maps:get(failed, MembershipStats)),

    %% Post creation
    %% The number of posts is determined by the popularity plan.
    PostPlan = maps:get(author_post_plan, Summary),

    ExpectedPosts = lists:sum([
        maps:get(posts, Plan)
        || Plan <- maps:values(PostPlan)
    ]),

    PostStats = maps:get(post_creation, Stats),

    ?assertEqual(
        ExpectedPosts,
        maps:get(attempted, PostStats)
    ),

    ?assertEqual(
        ExpectedPosts,
        maps:get(successful, PostStats)
    ),

    ?assertEqual(
        0,
        maps:get(failed, PostStats)
    ),

        %% Repost creation
    RepostStats = maps:get(repost_creation, Stats),
    ?assertEqual(12, maps:get(attempted, RepostStats)),
    ?assertEqual(12, maps:get(successful, RepostStats)),
    ?assertEqual(0, maps:get(failed, RepostStats)),

    %% Comment creation
    CommentStats = maps:get(comment_creation, Stats),
    ?assertEqual(12, maps:get(attempted, CommentStats)),
    ?assertEqual(12, maps:get(successful, CommentStats)),
    ?assertEqual(0, maps:get(failed, CommentStats)),

    %% Post voting
    VotingStats = maps:get(post_voting, Stats),
    ?assertEqual(12, maps:get(attempted, VotingStats)),
    ?assertEqual(12, maps:get(successful, VotingStats)),
    ?assertEqual(0, maps:get(failed, VotingStats)),

    %% Feed retrieval
    FeedStats = maps:get(feed_retrieval, Stats),
    ?assertEqual(12, maps:get(attempted, FeedStats)),
    ?assertEqual(12, maps:get(successful, FeedStats)),
    ?assertEqual(0, maps:get(failed, FeedStats)),

    %% Direct messages
    MessageStats = maps:get(direct_messages, Stats),
    ?assertEqual(12, maps:get(attempted, MessageStats)),
    ?assertEqual(12, maps:get(successful, MessageStats)),
    ?assertEqual(0, maps:get(failed, MessageStats)),

    %% Message replies
    ReplyStats = maps:get(message_replies, Stats),
    ?assertEqual(12, maps:get(attempted, ReplyStats)),
    ?assertEqual(12, maps:get(successful, ReplyStats)),
    ?assertEqual(0, maps:get(failed, ReplyStats)),

    %% Overall workload
    ?assertEqual(
        0,
        maps:get(failed_operations, Summary)
    ).



%% Test helpers

with_engine_client(Fun) ->
    Engine = reddit_engine:start_link(),
    Client = reddit_client:start_link(Engine),
    try
        Fun(Engine, Client)
    after
        reddit_client:stop(Client),
        reddit_engine:stop(Engine)
    end.

register_user(Client, Username) ->
    ?assertEqual(
        {ok, registered},
        reddit_client:register(Client, Username)
    ).

start_clients(Count, Engine) ->
    [
        reddit_client:start_link(Engine)
        || _ <- lists:seq(1, Count)
    ].

stop_clients(Clients) ->
    lists:foreach(fun reddit_client:stop/1, Clients).

collect_results(0, _Tag, Results) ->
    Results;
collect_results(Remaining, Tag, Results) ->
    receive
        {Tag, Result} ->
            collect_results(Remaining - 1, Tag, [Result | Results])
    after 10000 ->
        ?assert(false)
    end.

count_successes(Results) ->
    length([R || R <- Results, R =:= {ok, registered}]).
