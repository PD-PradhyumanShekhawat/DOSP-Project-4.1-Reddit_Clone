
-module(reddit_simulator).

-export([run/1]).

run(NumberOfUsers)
        when is_integer(NumberOfUsers), NumberOfUsers >= 0 ->
    EnginePid = reddit_engine:start_link(),

    try
        Clients = start_clients(NumberOfUsers, EnginePid),
        Parent = self(),

        StartTime = erlang:monotonic_time(microsecond),

        launch_registrations(Clients, Parent),

        Results = collect_results(NumberOfUsers, []),

        EndTime = erlang:monotonic_time(microsecond),

        ElapsedSeconds =
            (EndTime - StartTime) / 1000000,

        Successful = count_successes(Results),
        Failed = length(Results) - Successful,

        Throughput =
            case ElapsedSeconds > 0 of
                true -> Successful / ElapsedSeconds;
                false -> 0
            end,

        AccountCount = reddit_engine:account_count(EnginePid),

        Summary = #{
            requested_users => NumberOfUsers,
            successful_registrations => Successful,
            failed_registrations => Failed,
            engine_account_count => AccountCount,
            elapsed_seconds => ElapsedSeconds,
            throughput_per_second => Throughput
        },

        print_summary(Summary),
        stop_clients(Clients),
        Summary
    after
        reddit_engine:stop(EnginePid)
    end;

run(_) ->
    {error, invalid_user_count}.

start_clients(NumberOfUsers, EnginePid) ->
    [
        reddit_client:start_link(EnginePid)
        || _ <- lists:seq(1, NumberOfUsers)
    ].

launch_registrations(Clients, Parent) ->
    lists:foreach(
        fun({ClientPid, Index}) ->
            spawn(fun() ->
                Username = "user_" ++ integer_to_list(Index),
                Result = reddit_client:register(ClientPid, Username),
                Parent ! {sim_result, Index, Result}
            end)
        end,
        lists:zip(Clients, lists:seq(1, length(Clients)))
    ).

collect_results(0, Results) ->
    Results;

collect_results(Remaining, Results) ->
    receive
        {sim_result, _Index, Result} ->
            collect_results(Remaining - 1, [Result | Results])
    after 15000 ->
        [{error, simulator_timeout} | Results]
    end.

count_successes(Results) ->
    length([
        Result
        || Result <- Results,
           Result =:= {ok, registered}
    ]).

stop_clients(Clients) ->
    lists:foreach(
        fun(ClientPid) ->
            reddit_client:stop(ClientPid)
        end,
        Clients
    ).

print_summary(Summary) ->
    io:format("~n===== Reddit Simulator Results =====~n"),
    io:format("Requested users: ~p~n",
              [maps:get(requested_users, Summary)]),
    io:format("Successful registrations: ~p~n",
              [maps:get(successful_registrations, Summary)]),
    io:format("Failed registrations: ~p~n",
              [maps:get(failed_registrations, Summary)]),
    io:format("Engine account count: ~p~n",
              [maps:get(engine_account_count, Summary)]),
    io:format("Elapsed time: ~.6f seconds~n",
              [maps:get(elapsed_seconds, Summary)]),
    io:format("Throughput: ~.2f registrations/second~n",
              [maps:get(throughput_per_second, Summary)]),
    io:format("=====================================~n~n").
