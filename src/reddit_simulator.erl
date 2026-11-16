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
        Summary = #{
            requested_users => NumberOfUsers,
            successful_registrations => Successful,
            failed_registrations => Failed,
            engine_account_count => reddit_engine:account_count(EnginePid),
            elapsed_seconds => Elapsed,
            throughput_per_second => rate(Successful, Elapsed)
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

%% Options: #{subreddits => PositiveInteger}
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
                    Clients, SubredditCount
                ),
                PostResults = create_posts(
                    Clients, NumberOfUsers, SubredditCount
                ),
                PostIds = successful_ids(PostResults),
                CommentResults = create_comments(
                    Clients, NumberOfUsers, PostIds
                ),
                VoteResults = vote_on_posts(
                    Clients, NumberOfUsers, PostIds
                ),
                FeedResults = retrieve_feeds(Clients),
                MessageResults = send_messages(
                    Clients, NumberOfUsers
                ),
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
                    engine_account_count =>
                        reddit_engine:account_count(EnginePid),
                    elapsed_seconds => Elapsed,
                    successful_operations => TotalSuccessful,
                    failed_operations => TotalFailed,
                    operations_per_second =>
                        rate(TotalSuccessful, Elapsed),
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

configured_subreddit_count(NumberOfUsers, Options) ->
    Requested = maps:get(subreddits, Options, 5),
    case is_integer(Requested) andalso Requested >= 1 of
        true -> erlang:min(NumberOfUsers, Requested);
        false -> erlang:min(NumberOfUsers, 5)
    end.

register_clients(Clients) ->
    parallel_tasks([
        {Index, fun() ->
            reddit_client:register(Client, username(Index))
        end}
        || {Client, Index} <- indexed_clients(Clients)
    ]).

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

join_subreddits(Clients, SubredditCount) ->
    Tasks = [
        {{UserIndex, SubredditIndex}, fun() ->
            reddit_client:join_subreddit(
                lists:nth(UserIndex, Clients),
                username(UserIndex),
                subreddit_name(SubredditIndex)
            )
        end}
        || UserIndex <- lists:seq(1, length(Clients)),
           SubredditIndex <- lists:seq(1, SubredditCount),
           UserIndex =/= SubredditIndex
    ],
    parallel_tasks(Tasks).
create_posts(Clients, _NumberOfUsers, SubredditCount) ->
    parallel_tasks([
        {Index, fun() ->
            SubredditIndex = ((Index - 1) rem SubredditCount) + 1,
            reddit_client:create_post(
                lists:nth(Index, Clients),
                username(Index),
                subreddit_name(SubredditIndex),
                "Post created by " ++ username(Index)
            )
        end}
        || Index <- lists:seq(1, length(Clients))
    ]).

create_comments(_Clients, NumberOfUsers, _PostIds)
        when NumberOfUsers < 2 ->
    [];
create_comments(Clients, NumberOfUsers, PostIds) ->
    parallel_tasks([
        {Index, fun() ->
            TargetIndex = next_index(Index, NumberOfUsers),
            case maps:find(TargetIndex, PostIds) of
                {ok, PostId} ->
                    reddit_client:add_comment(
                        lists:nth(Index, Clients),
                        username(Index), PostId, none,
                        "Comment from " ++ username(Index)
                    );
                error ->
                    {error, target_post_unavailable}
            end
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).

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
                        username(Index), PostId, Vote
                    );
                error ->
                    {error, target_post_unavailable}
            end
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).

retrieve_feeds(Clients) ->
    parallel_tasks([
        {Index, fun() ->
            reddit_client:get_feed(Client, username(Index))
        end}
        || {Client, Index} <- indexed_clients(Clients)
    ]).

send_messages(_Clients, NumberOfUsers)
        when NumberOfUsers < 2 ->
    [];
send_messages(Clients, NumberOfUsers) ->
    parallel_tasks([
        {Index, fun() ->
            RecipientIndex = next_index(Index, NumberOfUsers),
            reddit_client:send_message(
                lists:nth(Index, Clients),
                username(Index), username(RecipientIndex),
                "Message from " ++ username(Index)
            )
        end}
        || Index <- lists:seq(1, NumberOfUsers)
    ]).

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
                        username(RecipientIndex), MessageId,
                        "Reply from " ++ username(RecipientIndex)
                    );
                error ->
                    {error, parent_message_unavailable}
            end
        end}
        || RecipientIndex <- lists:seq(1, NumberOfUsers)
    ]).

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

is_success({ok, _}) -> true;
is_success(_) -> false.
parallel_tasks(Tasks) ->
    Parent = self(),
    Tag = make_ref(),
    lists:foreach(
        fun({Key, TaskFun}) ->
            spawn(fun() ->
                Result = try TaskFun()
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
                Remaining - 1, Tag, [{Key, Result} | Results]
            )
    after 30000 ->
        lists:keysort(1, [
            {timeout, {error, simulator_timeout}} | Results
        ])
    end.

start_clients(NumberOfUsers, EnginePid) ->
    [
        reddit_client:start_link(EnginePid)
        || _ <- lists:seq(1, NumberOfUsers)
    ].

indexed_clients(Clients) ->
    lists:zip(Clients, lists:seq(1, length(Clients))).

stop_clients(Clients) ->
    lists:foreach(fun reddit_client:stop/1, Clients).

username(Index) ->
    "user_" ++ integer_to_list(Index).

subreddit_name(Index) ->
    "community_" ++ integer_to_list(Index).

next_index(Index, Count) ->
    (Index rem Count) + 1.

previous_index(1, Count) -> Count;
previous_index(Index, _Count) -> Index - 1.

elapsed_seconds(StartTime, EndTime) ->
    (EndTime - StartTime) / 1000000.

rate(_Count, Elapsed) when Elapsed =< 0 -> 0;
rate(Count, Elapsed) -> Count / Elapsed.

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
    io:format("Operation breakdown:~n"),
    case maps:find(operation_stats, Summary) of
        {ok, OperationStats} ->
            lists:foreach(
                fun({Operation, Counts}) ->
                    io:format(
                        "  ~p: attempted=~p successful=~p failed=~p~n",
                        [Operation,
                         maps:get(attempted, Counts),
                         maps:get(successful, Counts),
                         maps:get(failed, Counts)]
                    )
                end,
                lists:sort(maps:to_list(OperationStats))
            );
        error ->
            ok
    end,
    io:format("=========================================~n~n").