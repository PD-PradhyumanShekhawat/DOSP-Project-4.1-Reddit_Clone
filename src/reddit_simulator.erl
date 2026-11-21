-module(reddit_simulator).

-export([run/1, run_workload/1, run_workload/2]).

%% Backward-compatible registration-only benchmark.
run(NumberOfUsers)
        when is_integer(NumberOfUsers), NumberOfUsers >= 0 ->
    EnginePid = reddit_engine:start_link(),
    Clients = start_clients(NumberOfUsers, EnginePid),
    try
        StartTime = erlang:monotonic_time(microsecond),

        RegistrationResults = parallel_tasks([
            {Index, fun() ->
                reddit_client:register(Client, username(Index))
            end}
            || {Client, Index} <- indexed_clients(Clients)
        ]),

        EndTime = erlang:monotonic_time(microsecond),
        Elapsed = elapsed_seconds(StartTime, EndTime),
        Successful = count_successes(RegistrationResults),
        Failed = length(RegistrationResults) - Successful,
        Throughput = rate(Successful, Elapsed),

        Summary = #{
            requested_users => NumberOfUsers,
            successful_registrations => Successful,
            failed_registrations => Failed,
            engine_account_count => reddit_engine:account_count(EnginePid),
            elapsed_seconds => Elapsed,
            throughput_per_second => Throughput
        },

        print_registration_summary(Summary),
        Summary
    after
        stop_clients(Clients),
        reddit_engine:stop(EnginePid)
    end;
run(_) ->
    {error, invalid_user_count}.


run_workload(NumberOfUsers) ->
    run_workload(NumberOfUsers, #{}).


%% Full engine workload.
%% Options:
%%   #{subreddits => PositiveInteger}
%%   #{zipf_exponent => PositiveNumber}
run_workload(NumberOfUsers, Options)
        when is_integer(NumberOfUsers), NumberOfUsers >= 1,
             is_map(Options) ->
    EnginePid = reddit_engine:start_link(),
    Clients = start_clients(NumberOfUsers, EnginePid),
    try
        SubredditCount = configured_subreddit_count(
            NumberOfUsers, Options
        ),

        StartTime = erlang:monotonic_time(microsecond),

        ZipfExponent = configured_zipf_exponent(Options),
        MembershipPlan = zipf_membership_plan(
            NumberOfUsers, SubredditCount, ZipfExponent
        ),

        Registration = register_clients(Clients),
        SuccessfulRegistrations = count_successes(Registration),

        case SuccessfulRegistrations =:= NumberOfUsers of
            false ->
                Summary = #{
                    requested_users => NumberOfUsers,
                    successful_registrations => SuccessfulRegistrations,
                    failed_registrations =>
                        NumberOfUsers - SuccessfulRegistrations,
                    operation_stats => #{
                        registration => stats(Registration)
                    },
                    error => registration_phase_incomplete
                },
                print_workload_summary(Summary),
                Summary;

            true ->
                SubredditResults = create_subreddits(
                    Clients, SubredditCount
                ),

                MembershipResults = join_subreddits(
                    Clients, MembershipPlan
                ),

                MembershipDistribution = membership_distribution(
                    NumberOfUsers, SubredditCount, MembershipPlan
                ),

                PostPlan = author_post_plan(
                    NumberOfUsers,
                    MembershipDistribution,
                    MembershipPlan
                ),

                PostResults = create_posts(
                    Clients, NumberOfUsers, PostPlan
                ),

                PostIds = successful_ids(PostResults),

                RepostResults = create_reposts(
                    Clients, NumberOfUsers, PostIds, MembershipPlan
                ),

                %% Comments are assigned only to posts in subreddits
                %% where the commenting user is a member.
                CommentResults = create_comments(
                    Clients,
                    NumberOfUsers,
                    PostIds,
                    MembershipPlan
                ),

                VoteResults = vote_on_posts(
                    Clients, NumberOfUsers, PostIds
                ),

                FeedResults = retrieve_feeds(Clients),
                MessageResults = send_messages(Clients, NumberOfUsers),
                MessageIds = successful_ids(MessageResults),

                ReplyResults = reply_to_messages(
                    Clients, NumberOfUsers, MessageIds
                ),

                EndTime = erlang:monotonic_time(microsecond),
                Elapsed = elapsed_seconds(StartTime, EndTime),

                OperationStats = #{
                    registration => stats(Registration),
                    subreddit_creation => stats(SubredditResults),
                    subreddit_membership => stats(MembershipResults),
                    post_creation => stats(PostResults),
                    repost_creation => stats(RepostResults),
                    comment_creation => stats(CommentResults),
                    post_voting => stats(VoteResults),
                    feed_retrieval => stats(FeedResults),
                    direct_messages => stats(MessageResults),
                    message_replies => stats(ReplyResults)
                },

                TotalSuccessful = lists:sum([
                    maps:get(successful, S)
                    || S <- maps:values(OperationStats)
                ]),

                TotalFailed = lists:sum([
                    maps:get(failed, S)
                    || S <- maps:values(OperationStats)
                ]),

                Summary = #{
                    requested_users => NumberOfUsers,
                    subreddit_count => SubredditCount,
                    zipf_exponent => ZipfExponent,
                    membership_distribution => MembershipDistribution,
                    author_post_plan => PostPlan,
                    engine_account_count =>
                        reddit_engine:account_count(EnginePid),
                    elapsed_seconds => Elapsed,
                    successful_operations => TotalSuccessful,
                    failed_operations => TotalFailed,
                    operations_per_second => rate(
                        TotalSuccessful, Elapsed
                    ),
                    operation_stats => OperationStats
                },

                print_workload_summary(Summary),
                Summary
        end
    after
        stop_clients(Clients),
        reddit_engine:stop(EnginePid)
    end;
run_workload(_, _) ->
    {error, invalid_workload_configuration}.


%% Configuration

configured_subreddit_count(NumberOfUsers, Options) ->
    Requested = maps:get(subreddits, Options, 5),
    case is_integer(Requested) andalso Requested >= 1 of
        true ->
            erlang:min(NumberOfUsers, Requested);
        false ->
            erlang:min(NumberOfUsers, 5)
    end.


configured_zipf_exponent(Options) ->
    case maps:get(zipf_exponent, Options, 1.0) of
        Value when is_number(Value), Value > 0 ->
            Value;
        _ ->
            1.0
    end.


%% Registration

register_clients(Clients) ->
    parallel_tasks([
        {Index, fun() ->
            reddit_client:register(Client, username(Index))
        end}
        || {Client, Index} <- indexed_clients(Clients)
    ]).


%% Subreddit creation and membership

create_subreddits(Clients, Count) ->
    parallel_tasks([
        {Index, fun() ->
            reddit_client:create_subreddit(
                lists:nth(Index, Clients),
                username(Index),
                subreddit_name(Index)
            )
        end}
        || Index <- lists:seq(1, Count)
    ]).


join_subreddits(Clients, MembershipPlan) ->
    parallel_tasks([
        {UserIndex, fun() ->
            reddit_client:join_subreddit(
                lists:nth(UserIndex, Clients),
                username(UserIndex),
                subreddit_name(SubredditIndex)
            )
        end}
        || {UserIndex, SubredditIndex} <- maps:to_list(MembershipPlan),
           UserIndex =/= SubredditIndex
    ]).


%% Each user is assigned one subreddit using a deterministic
%% inverse-CDF Zipf distribution. The subreddit creator is
%% already a member of their own subreddit.
zipf_membership_plan(UserCount, SubredditCount, Exponent) ->
    Weights = [
        1 / math:pow(Rank, Exponent)
        || Rank <- lists:seq(1, SubredditCount)
    ],

    TotalWeight = lists:sum(Weights),

    Cumulative = cumulative_weights(
        Weights, TotalWeight, 0.0, []
    ),

    maps:from_list([
        {
            UserIndex,
            choose_zipf_rank(zipf_unit(UserIndex), Cumulative)
        }
        || UserIndex <- lists:seq(1, UserCount)
    ]).


cumulative_weights([], _Total, _Running, Acc) ->
    lists:reverse(Acc);

cumulative_weights([Weight | Rest], Total, Running, Acc) ->
    Next = Running + Weight / Total,
    cumulative_weights(Rest, Total, Next, [Next | Acc]).


zipf_unit(Index) ->
    Fraction = Index * 0.6180339887498949,
    Fraction - math:floor(Fraction).


choose_zipf_rank(_Value, []) ->
    1;

choose_zipf_rank(Value, Thresholds) ->
    choose_zipf_rank_index(Value, Thresholds, 1).


choose_zipf_rank_index(_Value, [], Rank) ->
    Rank;

choose_zipf_rank_index(Value, [Threshold | _], Rank)
        when Value =< Threshold ->
    Rank;

choose_zipf_rank_index(Value, [_ | Rest], Rank) ->
    choose_zipf_rank_index(Value, Rest, Rank + 1).


membership_distribution(_UserCount, SubredditCount, MembershipPlan) ->
    Base = maps:from_list([
        {Rank, 1}
        || Rank <- lists:seq(1, SubredditCount)
    ]),

    Counts = maps:fold(
        fun(UserIndex, SubredditIndex, Acc) ->
            case UserIndex =:= SubredditIndex of
                true ->
                    Acc;
                false ->
                    maps:update_with(
                        SubredditIndex,
                        fun(Count) -> Count + 1 end,
                        1,
                        Acc
                    )
            end
        end,
        Base,
        MembershipPlan
    ),

    maps:from_list([
        {
            subreddit_name(Rank),
            maps:get(Rank, Counts, 0)
        }
        || Rank <- lists:seq(1, SubredditCount)
    ]).


%% Popularity-based posting plan.
%% Users with larger simulated audiences create more posts.
author_post_plan(UserCount, MembershipDistribution, MembershipPlan) ->
    maps:from_list([
        begin
            SubredditIndex = maps:get(UserIndex, MembershipPlan),

            MemberCount = maps:get(
                subreddit_name(SubredditIndex),
                MembershipDistribution
            ),

            %% Lower-index accounts receive larger simulated audiences.
            SubscriberCount = max(1, UserCount div UserIndex),

            PopularityBonus = min(2, floor_log2(MemberCount)),
            AudienceBonus = min(2, floor_log2(SubscriberCount)),

            {
                UserIndex,
                #{
                    subreddit => SubredditIndex,
                    simulated_subscribers => SubscriberCount,
                    posts => min(
                        6,
                        1 + PopularityBonus + AudienceBonus
                    )
                }
            }
        end
        || UserIndex <- lists:seq(1, UserCount)
    ]).


floor_log2(Value) when Value =< 1 ->
    0;

floor_log2(Value) ->
    trunc(math:log(Value) / math:log(2)).


%% Post creation

create_posts(Clients, _NumberOfUsers, PostPlan) ->
    Tasks = lists:append([
        begin
            Plan = maps:get(UserIndex, PostPlan),
            SubredditIndex = maps:get(subreddit, Plan),
            PostCount = maps:get(posts, Plan),

            [
                {
                    post_task_key(UserIndex, Sequence),
                    fun() ->
                        Content = case Sequence of
                            1 ->
                                "Post created by " ++ username(UserIndex);
                            _ ->
                                "Additional post "
                                ++ integer_to_list(Sequence)
                                ++ " by "
                                ++ username(UserIndex)
                        end,

                        reddit_client:create_post(
                            lists:nth(UserIndex, Clients),
                            username(UserIndex),
                            subreddit_name(SubredditIndex),
                            Content
                        )
                    end
                }
                || Sequence <- lists:seq(1, PostCount)
            ]
        end
        || UserIndex <- lists:seq(1, length(Clients))
    ]),

    parallel_tasks(Tasks).


post_task_key(UserIndex, 1) ->
    UserIndex;

post_task_key(UserIndex, Sequence) ->
    {additional_post, UserIndex, Sequence}.


%% Repost creation
%% Each user reposts a post from their assigned subreddit. The helper
%% selects another member's post when possible and falls back to the
%% user's own post when they are the only member of that subreddit.
create_reposts(_Clients, NumberOfUsers, _PostIds, _MembershipPlan)
        when NumberOfUsers < 1 ->
    [];

create_reposts(Clients, NumberOfUsers, PostIds, MembershipPlan) ->
    parallel_tasks([
        {Index, fun() ->
            SubredditIndex = maps:get(Index, MembershipPlan),
            TargetAuthorIndex = choose_comment_target(
                Index,
                SubredditIndex,
                NumberOfUsers,
                MembershipPlan
            ),

            case maps:find(TargetAuthorIndex, PostIds) of
                {ok, PostId} ->
                    reddit_client:repost(
                        lists:nth(Index, Clients),
                        username(Index),
                        PostId
                    );
                error ->
                    {error, target_post_unavailable}
            end
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).


%% Comment creation
%%
%% Each commenter is assigned a post from their own subreddit.
%% This prevents membership-validation failures.
%%
%% The simulator prefers another member's post. If the commenter
%% is the only member of that subreddit, their own post is used.
create_comments(
    _Clients,
    NumberOfUsers,
    _PostIds,
    _MembershipPlan
)
        when NumberOfUsers < 2 ->
    [];

create_comments(Clients, NumberOfUsers, PostIds, MembershipPlan) ->
    parallel_tasks([
        {Index, fun() ->
            SubredditIndex = maps:get(Index, MembershipPlan),

            TargetAuthorIndex = choose_comment_target(
                Index,
                SubredditIndex,
                NumberOfUsers,
                MembershipPlan
            ),

            case maps:find(TargetAuthorIndex, PostIds) of
                {ok, PostId} ->
                    reddit_client:add_comment(
                        lists:nth(Index, Clients),
                        username(Index),
                        PostId,
                        none,
                        "Comment from " ++ username(Index)
                    );

                error ->
                    {error, target_post_unavailable}
            end
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).


choose_comment_target(
    CommenterIndex,
    SubredditIndex,
    NumberOfUsers,
    MembershipPlan
) ->
    Members = [
        UserIndex
        || UserIndex <- lists:seq(1, NumberOfUsers),
           maps:get(UserIndex, MembershipPlan) =:= SubredditIndex
    ],

    OtherMembers = [
        UserIndex
        || UserIndex <- Members,
           UserIndex =/= CommenterIndex
    ],

    case OtherMembers of
        [TargetIndex | _] ->
            TargetIndex;

        [] ->
            CommenterIndex
    end.


%% Post voting

vote_on_posts(_Clients, NumberOfUsers, _PostIds)
        when NumberOfUsers < 2 ->
    [];

vote_on_posts(Clients, NumberOfUsers, PostIds) ->
    parallel_tasks([
        {Index, fun() ->
            TargetIndex = next_index(Index, NumberOfUsers),

            case maps:find(TargetIndex, PostIds) of
                {ok, PostId} ->
                    Vote = case Index rem 2 of
                        0 -> upvote;
                        1 -> downvote
                    end,

                    reddit_client:vote_post(
                        lists:nth(Index, Clients),
                        username(Index),
                        PostId,
                        Vote
                    );

                error ->
                    {error, target_post_unavailable}
            end
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).


%% Feed retrieval

retrieve_feeds(Clients) ->
    parallel_tasks([
        {Index, fun() ->
            reddit_client:get_feed(Client, username(Index))
        end}
        || {Client, Index} <- indexed_clients(Clients)
    ]).


%% Direct messages

send_messages(_Clients, NumberOfUsers)
        when NumberOfUsers < 2 ->
    [];

send_messages(Clients, NumberOfUsers) ->
    parallel_tasks([
        {Index, fun() ->
            RecipientIndex = next_index(Index, NumberOfUsers),

            reddit_client:send_message(
                lists:nth(Index, Clients),
                username(Index),
                username(RecipientIndex),
                "Message from " ++ username(Index)
            )
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).


%% Replies to direct messages

reply_to_messages(_Clients, NumberOfUsers, _MessageIds)
        when NumberOfUsers < 2 ->
    [];

reply_to_messages(Clients, NumberOfUsers, MessageIds) ->
    parallel_tasks([
        {RecipientIndex, fun() ->
            SenderIndex = previous_index(
                RecipientIndex, NumberOfUsers
            ),

            case maps:find(SenderIndex, MessageIds) of
                {ok, MessageId} ->
                    reddit_client:reply_to_message(
                        lists:nth(RecipientIndex, Clients),
                        username(RecipientIndex),
                        MessageId,
                        "Reply from " ++ username(RecipientIndex)
                    );

                error ->
                    {error, parent_message_unavailable}
            end
        end}
        || RecipientIndex <- lists:seq(1, NumberOfUsers)
    ]).


%% Result processing

successful_ids(Results) ->
    maps:from_list([
        {Key, Id}
        || {Key, {ok, Id}} <- Results,
           is_integer(Id)
    ]).


stats(Results) ->
    Successful = count_successes(Results),

    #{
        attempted => length(Results),
        successful => Successful,
        failed => length(Results) - Successful
    }.


count_successes(Results) ->
    length([
        ok
        || {_Key, Result} <- Results,
           is_success(Result)
    ]).


is_success({ok, _}) ->
    true;

is_success(_) ->
    false.


%% Parallel task execution

parallel_tasks(Tasks) ->
    Parent = self(),
    Tag = make_ref(),

    lists:foreach(
        fun({Key, TaskFun}) ->
            spawn(fun() ->
                Result = try
                    TaskFun()
                catch
                    Class:Reason ->
                        {error, {Class, Reason}}
                end,

                Parent ! {Tag, Key, Result}
            end)
        end,
        Tasks
    ),

    collect_tasks(length(Tasks), Tag, []).


collect_tasks(0, _Tag, Results) ->
    lists:keysort(1, Results);

collect_tasks(Remaining, Tag, Results) ->
    receive
        {Tag, Key, Result} ->
            collect_tasks(
                Remaining - 1,
                Tag,
                [{Key, Result} | Results]
            )
    after 30000 ->
        lists:keysort(1, [
            {timeout, {error, simulator_timeout}} | Results
        ])
    end.


%% Client lifecycle

start_clients(NumberOfUsers, EnginePid) ->
    [
        reddit_client:start_link(EnginePid)
        || _ <- lists:seq(1, NumberOfUsers)
    ].


indexed_clients(Clients) ->
    lists:zip(Clients, lists:seq(1, length(Clients))).


stop_clients(Clients) ->
    lists:foreach(fun reddit_client:stop/1, Clients).


%% Names and indexing

username(Index) ->
    "user_" ++ integer_to_list(Index).


subreddit_name(Index) ->
    "community_" ++ integer_to_list(Index).


next_index(Index, Count) ->
    (Index rem Count) + 1.


previous_index(1, Count) ->
    Count;

previous_index(Index, _Count) ->
    Index - 1.


%% Timing and throughput

elapsed_seconds(StartTime, EndTime) ->
    (EndTime - StartTime) / 1000000.


rate(_Count, Elapsed) when Elapsed =< 0 ->
    0;

rate(Count, Elapsed) ->
    Count / Elapsed.


%% Registration benchmark output

print_registration_summary(Summary) ->
    io:format("~n===== Reddit Registration Benchmark =====~n"),

    io:format("Requested users: ~p~n", [
        maps:get(requested_users, Summary)
    ]),

    io:format("Successful registrations: ~p~n", [
        maps:get(successful_registrations, Summary)
    ]),

    io:format("Failed registrations: ~p~n", [
        maps:get(failed_registrations, Summary)
    ]),

    io:format("Engine account count: ~p~n", [
        maps:get(engine_account_count, Summary)
    ]),

    io:format("Elapsed time: ~.6f seconds~n", [
        maps:get(elapsed_seconds, Summary)
    ]),

    io:format("Throughput: ~.2f registrations/second~n", [
        maps:get(throughput_per_second, Summary)
    ]),

    io:format("==========================================~n~n").


%% Full workload output

print_workload_summary(Summary) ->
    io:format("~n===== Reddit Full Workload Results =====~n"),

    io:format("Requested users: ~p~n", [
        maps:get(requested_users, Summary)
    ]),

    io:format("Subreddits: ~p~n", [
        maps:get(subreddit_count, Summary, 0)
    ]),

    io:format("Engine account count: ~p~n", [
        maps:get(engine_account_count, Summary, unavailable)
    ]),

    io:format("Elapsed time: ~.6f seconds~n", [
        maps:get(elapsed_seconds, Summary, 0.0)
    ]),

    io:format("Successful operations: ~p~n", [
        maps:get(successful_operations, Summary, 0)
    ]),

    io:format("Failed operations: ~p~n", [
        maps:get(failed_operations, Summary, 0)
    ]),

    io:format("Operations/second: ~.2f~n", [
        maps:get(operations_per_second, Summary, 0.0)
    ]),

    case maps:find(membership_distribution, Summary) of
        {ok, Distribution} ->
            io:format("Subreddit membership distribution: ~p~n", [
                Distribution
            ]);
        error ->
            ok
    end,

    io:format("Operation breakdown:~n"),

    case maps:find(operation_stats, Summary) of
        {ok, OperationStats} ->
            lists:foreach(
                fun({Operation, Counts}) ->
                    io:format(
                        "  ~p: attempted=~p successful=~p failed=~p~n",
                        [
                            Operation,
                            maps:get(attempted, Counts),
                            maps:get(successful, Counts),
                            maps:get(failed, Counts)
                        ]
                    )
                end,
                lists:sort(maps:to_list(OperationStats))
            );
        error ->
            ok
    end,

    io:format("=========================================~n~n").