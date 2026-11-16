
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
