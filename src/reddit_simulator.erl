-module(reddit_simulator).

-export([run/1, run_workload/1, run_workload/2, run_lifecycle/2]).

%% Keep the single engine mailbox bounded under large simulated workloads.
-define(MAX_IN_FLIGHT, 16).
-define(TASK_BATCH_TIMEOUT_MS, 15000).

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

        {Registration, RegistrationMs} = timed_phase(fun() ->
            register_clients(Clients)
        end),
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
                {SubredditResults, SubredditCreationMs} = timed_phase(fun() ->
                    create_subreddits(Clients, SubredditCount)
                end),

                {MembershipResults, MembershipMs} = timed_phase(fun() ->
                    join_subreddits(Clients, MembershipPlan)
                end),

                MembershipDistribution = membership_distribution(
                    NumberOfUsers, SubredditCount, MembershipPlan
                ),

                PostPlan = author_post_plan(
                    NumberOfUsers,
                    MembershipDistribution,
                    MembershipPlan
                ),

                {PostResults, PostCreationMs} = timed_phase(fun() ->
                    create_posts(Clients, NumberOfUsers, PostPlan)
                end),

                PostIds = successful_ids(PostResults),

                {RepostResults, RepostCreationMs} = timed_phase(fun() ->
                    create_reposts(
                        Clients, NumberOfUsers, PostIds, MembershipPlan
                    )
                end),

                %% Comments are assigned only to posts in subreddits
                %% where the commenting user is a member.
                {CommentResults, CommentCreationMs} = timed_phase(fun() ->
                    create_comments(
                        Clients,
                        NumberOfUsers,
                        PostIds,
                        MembershipPlan
                    )
                end),

                {VoteResults, VotingMs} = timed_phase(fun() ->
                    vote_on_posts(Clients, NumberOfUsers, PostIds)
                end),

                {FeedResults, FeedRetrievalMs} = timed_phase(fun() ->
                    retrieve_feeds(Clients)
                end),
                {MessageResults, DirectMessagesMs} = timed_phase(fun() ->
                    send_messages(Clients, NumberOfUsers)
                end),
                MessageIds = successful_ids(MessageResults),

                {ReplyResults, MessageRepliesMs} = timed_phase(fun() ->
                    reply_to_messages(Clients, NumberOfUsers, MessageIds)
                end),

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
                    feed_entries_returned => feed_entry_count(FeedResults),
                    max_in_flight_operations => ?MAX_IN_FLIGHT,
                    phase_durations_ms => #{
                        registration => RegistrationMs,
                        subreddit_creation => SubredditCreationMs,
                        subreddit_membership => MembershipMs,
                        post_creation => PostCreationMs,
                        repost_creation => RepostCreationMs,
                        comment_creation => CommentCreationMs,
                        post_voting => VotingMs,
                        feed_retrieval => FeedRetrievalMs,
                        direct_messages => DirectMessagesMs,
                        message_replies => MessageRepliesMs
                    },
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


%% Online/offline lifecycle experiment.
%% Options:
%%   #{duration_ms => PositiveInteger,
%%     online_ms => PositiveInteger,
%%     offline_ms => PositiveInteger,
%%     operation_interval_ms => PositiveInteger}
%% Each simulated client repeatedly alternates between online and offline
%% periods. While offline, attempted feed requests must be rejected locally
%% by the client actor and must not reach the engine.
run_lifecycle(NumberOfUsers, Options)
        when is_integer(NumberOfUsers), NumberOfUsers >= 1,
             is_map(Options) ->
    case lifecycle_config(Options) of
        {ok, Config} ->
            EnginePid = reddit_engine:start_link(),
            Clients = start_clients(NumberOfUsers, EnginePid),
            try
                Registration = register_clients(Clients),
                case count_successes(Registration) =:= NumberOfUsers of
                    false ->
                        {error, registration_phase_incomplete};
                    true ->
                        StartTime = erlang:monotonic_time(millisecond),
                        Duration = maps:get(duration_ms, Config),
                        Deadline = StartTime + Duration,
                        Parent = self(),
                        [
                            spawn(fun() ->
                                lifecycle_client(
                                    Parent, Client, username(Index),
                                    Deadline, Config, empty_lifecycle_stats()
                                )
                            end)
                            || {Client, Index} <- indexed_clients(Clients)
                        ],
                        PerClient = collect_lifecycle_results(
                            NumberOfUsers, []
                        ),
                        EndTime = erlang:monotonic_time(millisecond),
                        Totals = combine_lifecycle_stats(PerClient),
                        Summary = Totals#{
                            requested_users => NumberOfUsers,
                            duration_ms => EndTime - StartTime,
                            configured_duration_ms => Duration,
                            online_ms => maps:get(online_ms, Config),
                            offline_ms => maps:get(offline_ms, Config),
                            operation_interval_ms =>
                                maps:get(operation_interval_ms, Config),
                            engine_account_count =>
                                reddit_engine:account_count(EnginePid)
                        },
                        print_lifecycle_summary(Summary),
                        Summary
                end
            after
                stop_clients(Clients),
                reddit_engine:stop(EnginePid)
            end;
        Error ->
            Error
    end;
run_lifecycle(_, _) ->
    {error, invalid_lifecycle_configuration}.

lifecycle_config(Options) ->
    Defaults = #{
        duration_ms => 1000,
        online_ms => 200,
        offline_ms => 100,
        operation_interval_ms => 25
    },
    Config = maps:merge(Defaults, Options),
    Values = [
        maps:get(duration_ms, Config),
        maps:get(online_ms, Config),
        maps:get(offline_ms, Config),
        maps:get(operation_interval_ms, Config)
    ],
    case lists:all(
        fun(Value) -> is_integer(Value) andalso Value > 0 end,
        Values
    ) of
        true -> {ok, Config};
        false -> {error, invalid_lifecycle_configuration}
    end.

empty_lifecycle_stats() ->
    #{
        connection_attempts => 0,
        successful_connections => 0,
        disconnections => 0,
        online_time_ms => 0,
        offline_time_ms => 0,
        attempted => 0,
        successful => 0,
        offline_rejected => 0,
        failed => 0
    }.

lifecycle_client(Parent, Client, Username, Deadline, Config, Stats0) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            Parent ! {lifecycle_complete, self(), Stats0};
        false ->
            OnlineMs = maps:get(online_ms, Config),
            OfflineMs = maps:get(offline_ms, Config),
            Interval = maps:get(operation_interval_ms, Config),
            ConnectResult = reddit_client:connect(Client),
            StatsConnected = record_connection(ConnectResult, Stats0),
            OnlineStart = erlang:monotonic_time(millisecond),
            OnlineEnd = min(OnlineStart + OnlineMs, Deadline),
            Stats1 = lifecycle_phase(
                online, Client, Username, OnlineEnd, Interval, StatsConnected
            ),
            OnlineElapsed = max(
                0, erlang:monotonic_time(millisecond) - OnlineStart
            ),
            StatsOnline = add_lifecycle_time(online_time_ms, OnlineElapsed, Stats1),
            DisconnectResult = reddit_client:disconnect(Client),
            StatsDisconnected = record_disconnection(
                DisconnectResult, StatsOnline
            ),
            OfflineStart = erlang:monotonic_time(millisecond),
            OfflineEnd = min(OfflineStart + OfflineMs, Deadline),
            Stats2 = lifecycle_phase(
                offline, Client, Username, OfflineEnd, Interval, StatsDisconnected
            ),
            OfflineElapsed = max(
                0, erlang:monotonic_time(millisecond) - OfflineStart
            ),
            Stats3 = add_lifecycle_time(offline_time_ms, OfflineElapsed, Stats2),
            lifecycle_client(
                Parent, Client, Username, Deadline, Config, Stats3
            )
    end.

record_connection({ok, _Status}, Stats) ->
    Stats#{
        connection_attempts := maps:get(connection_attempts, Stats) + 1,
        successful_connections := maps:get(successful_connections, Stats) + 1
    };
record_connection(_Result, Stats) ->
    Stats#{connection_attempts := maps:get(connection_attempts, Stats) + 1}.

record_disconnection({ok, _Status}, Stats) ->
    Stats#{disconnections := maps:get(disconnections, Stats) + 1};
record_disconnection(_Result, Stats) ->
    Stats.

add_lifecycle_time(Key, Milliseconds, Stats) ->
    Stats#{Key := maps:get(Key, Stats) + Milliseconds}.

lifecycle_phase(Phase, Client, Username, PhaseEnd, Interval, Stats) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= PhaseEnd of
        true -> Stats;
        false ->
            Result = reddit_client:get_feed(Client, Username),
            Updated = record_lifecycle_result(Phase, Result, Stats),
            Remaining = PhaseEnd - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                true -> timer:sleep(min(Interval, Remaining));
                false -> ok
            end,
            lifecycle_phase(
                Phase, Client, Username, PhaseEnd, Interval, Updated
            )
    end.

record_lifecycle_result(_Phase, {ok, _}, Stats) ->
    Stats#{
        attempted := maps:get(attempted, Stats) + 1,
        successful := maps:get(successful, Stats) + 1
    };
record_lifecycle_result(offline, {error, offline}, Stats) ->
    Stats#{
        attempted := maps:get(attempted, Stats) + 1,
        offline_rejected := maps:get(offline_rejected, Stats) + 1
    };
record_lifecycle_result(_Phase, _Result, Stats) ->
    Stats#{
        attempted := maps:get(attempted, Stats) + 1,
        failed := maps:get(failed, Stats) + 1
    }.

collect_lifecycle_results(0, Results) ->
    Results;
collect_lifecycle_results(Remaining, Results) ->
    receive
        {lifecycle_complete, _Pid, Stats} ->
            collect_lifecycle_results(Remaining - 1, [Stats | Results])
    after 30000 ->
        collect_lifecycle_results(Remaining - 1, [empty_lifecycle_stats() | Results])
    end.

combine_lifecycle_stats(StatsList) ->
    lists:foldl(
        fun(Stats, Acc) ->
            maps:map(
                fun(Key, Value) -> Value + maps:get(Key, Stats) end,
                Acc
            )
        end,
        empty_lifecycle_stats(),
        StatsList
    ).

print_lifecycle_summary(Summary) ->
    io:format("~n===== Reddit Client Lifecycle Results =====~n"),
    io:format("Clients: ~p~n", [maps:get(requested_users, Summary)]),
    io:format("Elapsed: ~p ms~n", [maps:get(duration_ms, Summary)]),
    io:format("Connection attempts: ~p~n", [maps:get(connection_attempts, Summary)]),
    io:format("Successful connections: ~p~n", [maps:get(successful_connections, Summary)]),
    io:format("Disconnections: ~p~n", [maps:get(disconnections, Summary)]),
    io:format("Accumulated online time: ~p ms~n", [maps:get(online_time_ms, Summary)]),
    io:format("Accumulated offline time: ~p ms~n", [maps:get(offline_time_ms, Summary)]),
    io:format("Operations attempted: ~p~n", [maps:get(attempted, Summary)]),
    io:format("Successful online operations: ~p~n", [maps:get(successful, Summary)]),
    io:format("Rejected while offline: ~p~n", [maps:get(offline_rejected, Summary)]),
    io:format("Other failures: ~p~n", [maps:get(failed, Summary)]),
    io:format("Engine accounts: ~p~n", [maps:get(engine_account_count, Summary)]),
    io:format("===========================================~n~n").


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
            case reddit_client:get_feed(Client, username(Index)) of
                {ok, Feed} when is_list(Feed) ->
                    %% Retain only the measurement, not the full feed payload.
                    {ok, length(Feed)};
                Error ->
                    Error
            end
        end}
        || {Client, Index} <- indexed_clients(Clients)
    ]).

feed_entry_count(FeedResults) ->
    lists:sum([
        Count
        || {_Index, {ok, Count}} <- FeedResults,
           is_integer(Count)
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
    FailureReasons = lists:foldl(
        fun({_Key, {error, Reason}}, Accumulator) ->
                increment_counter(Reason, Accumulator);
           ({_Key, OtherResult}, Accumulator) ->
                case is_success(OtherResult) of
                    true -> Accumulator;
                    false -> increment_counter(
                        {unexpected_result, OtherResult}, Accumulator
                    )
                end
        end,
        #{},
        Results
    ),
    #{
        attempted => length(Results),
        successful => Successful,
        failed => length(Results) - Successful,
        failure_reasons => FailureReasons
    }.

increment_counter(Key, Counters) ->
    maps:put(Key, maps:get(Key, Counters, 0) + 1, Counters).


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

%% The assignment requires one central engine. Bound the number of client
%% requests submitted at once to provide backpressure instead of flooding its
%% mailbox with one worker per simulated user.
parallel_tasks(Tasks) ->
    parallel_tasks(Tasks, ?MAX_IN_FLIGHT, []).

parallel_tasks([], _Limit, AccumulatedResults) ->
    lists:keysort(1, AccumulatedResults);
parallel_tasks(Tasks, Limit, AccumulatedResults) ->
    {Batch, RemainingTasks} = take_task_batch(Tasks, Limit),
    BatchResults = run_task_batch(Batch),
    parallel_tasks(
        RemainingTasks, Limit, BatchResults ++ AccumulatedResults
    ).

take_task_batch(Tasks, Limit) ->
    take_task_batch(Tasks, Limit, []).

take_task_batch(Remaining, 0, Accumulator) ->
    {lists:reverse(Accumulator), Remaining};
take_task_batch([], _Limit, Accumulator) ->
    {lists:reverse(Accumulator), []};
take_task_batch([Task | Rest], Limit, Accumulator) ->
    take_task_batch(Rest, Limit - 1, [Task | Accumulator]).

run_task_batch(Tasks) ->
    Parent = self(),
    Tag = make_ref(),
    PendingKeys = [Key || {Key, _TaskFun} <- Tasks],
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
    collect_tasks(length(Tasks), Tag, [], PendingKeys).

collect_tasks(0, _Tag, Results, _PendingKeys) ->
    lists:keysort(1, Results);
collect_tasks(Remaining, Tag, Results, PendingKeys) ->
    receive
        {Tag, Key, Result} ->
            collect_tasks(
                Remaining - 1,
                Tag,
                [{Key, Result} | Results],
                lists:delete(Key, PendingKeys)
            )
    after ?TASK_BATCH_TIMEOUT_MS ->
        TimeoutResults = [
            {Key, {error, simulator_timeout}}
            || Key <- PendingKeys
        ],
        lists:keysort(1, TimeoutResults ++ Results)
    end.

timed_phase(Fun) ->
    Start = erlang:monotonic_time(microsecond),
    Result = Fun(),
    End = erlang:monotonic_time(microsecond),
    {Result, (End - Start) / 1000}.


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
                    ),
                    case maps:get(failure_reasons, Counts, #{}) of
                        Reasons when map_size(Reasons) > 0 ->
                            io:format("      failure_reasons=~p~n", [Reasons]);
                        _ ->
                            ok
                    end
                end,
                lists:sort(maps:to_list(OperationStats))
            );
        error ->
            ok
    end,

    case maps:find(phase_durations_ms, Summary) of
        {ok, PhaseDurations} ->
            io:format("Phase durations (ms): ~p~n", [PhaseDurations]);
        error ->
            ok
    end,
    io:format("Feed entries returned: ~p~n", [
        maps:get(feed_entries_returned, Summary, unavailable)
    ]),
    io:format("Max in-flight operations: ~p~n", [
        maps:get(max_in_flight_operations, Summary, unavailable)
    ]),
    io:format("=========================================~n~n").
