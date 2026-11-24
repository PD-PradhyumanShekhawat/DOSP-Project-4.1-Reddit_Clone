
-module(performance_test).

-export([run/0, run/2]).

-define(DEFAULT_USER_COUNTS, [25, 50, 100, 250, 500]).
-define(DEFAULT_REPETITIONS, 3).

run() ->
    run(?DEFAULT_USER_COUNTS, ?DEFAULT_REPETITIONS).

run(UserCounts, Repetitions)
        when is_list(UserCounts), UserCounts =/= [],
             is_integer(Repetitions), Repetitions >= 1 ->
    case valid_user_counts(UserCounts) of
        true ->
            ok = filelib:ensure_dir("results/benchmark_summary.csv"),

            io:format("~nStarting performance benchmark~n"),
            io:format("User counts: ~p; repetitions: ~p~n",
                      [UserCounts, Repetitions]),

            %% Warm-up run; excluded from recorded results.
            _ = reddit_simulator:run_workload(
                5, #{subreddits => 3}
            ),

            Rows = run_configurations(
                UserCounts, Repetitions, []
            ),

            SummaryPath = "results/benchmark_summary.csv",
            OperationsPath = "results/benchmark_operations.csv",

            ok = write_summary_csv(SummaryPath, Rows),
            ok = write_operation_csv(OperationsPath, Rows),

            ExpectedRuns = length(UserCounts) * Repetitions,

            io:format("~nBenchmark results saved.~n"),
            io:format("Summary: ~s~n", [SummaryPath]),
            io:format("Operations: ~s~n", [OperationsPath]),

            case length(Rows) =:= ExpectedRuns of
                true ->
                    {ok, #{runs => length(Rows)}};
                false ->
                    {error, {
                        incomplete_benchmark,
                        length(Rows),
                        ExpectedRuns
                    }}
            end;

        false ->
            {error, invalid_user_counts}
    end;

run(_, _) ->
    {error, invalid_benchmark_configuration}.


valid_user_counts(Counts) ->
    lists:all(
        fun(Count) ->
            is_integer(Count) andalso Count >= 1
        end,
        Counts
    ).


run_configurations([], _Repetitions, Acc) ->
    lists:reverse(Acc);

run_configurations([UserCount | Rest], Repetitions, Acc) ->
    io:format("~n--- Benchmarking ~p users ---~n", [UserCount]),

    NewRows = run_repetitions(
        UserCount, Repetitions, 1, []
    ),

    run_configurations(
        Rest,
        Repetitions,
        lists:reverse(NewRows) ++ Acc
    ).


run_repetitions(_UserCount, Repetitions, RunNumber, Acc)
        when RunNumber > Repetitions ->
    lists:reverse(Acc);

run_repetitions(UserCount, Repetitions, RunNumber, Acc) ->
    io:format(
        "Run ~p of ~p for ~p users~n",
        [RunNumber, Repetitions, UserCount]
    ),

    Result = reddit_simulator:run_workload(
        UserCount,
        #{subreddits => erlang:min(UserCount, 5)}
    ),

    case Result of
        Summary when is_map(Summary) ->
            case maps:is_key(elapsed_seconds, Summary) of
                true ->
                    Row = #{
                        users => UserCount,
                        repetition => RunNumber,
                        elapsed_seconds =>
                            maps:get(elapsed_seconds, Summary),
                        successful_operations =>
                            maps:get(successful_operations, Summary, 0),
                        failed_operations =>
                            maps:get(failed_operations, Summary, 0),
                        operations_per_second =>
                            maps:get(operations_per_second, Summary, 0.0),
                        operation_stats =>
                            maps:get(operation_stats, Summary, #{})
                    },

                    run_repetitions(
                        UserCount,
                        Repetitions,
                        RunNumber + 1,
                        [Row | Acc]
                    );

                false ->
                    io:format(
                        "Benchmark run incomplete: ~p~n",
                        [Summary]
                    ),

                    run_repetitions(
                        UserCount,
                        Repetitions,
                        RunNumber + 1,
                        Acc
                    )
            end;

        Other ->
            io:format("Benchmark run failed: ~p~n", [Other]),

            run_repetitions(
                UserCount,
                Repetitions,
                RunNumber + 1,
                Acc
            )
    end.


write_summary_csv(Path, Rows) ->
    Header =
        "users,repetition,elapsed_seconds,"
        "successful_operations,failed_operations,"
        "operations_per_second\n",

    Body = [
        io_lib:format("~B,~B,~.6f,~B,~B,~.2f~n", [
            maps:get(users, Row),
            maps:get(repetition, Row),
            maps:get(elapsed_seconds, Row),
            maps:get(successful_operations, Row),
            maps:get(failed_operations, Row),
            maps:get(operations_per_second, Row)
        ])
        || Row <- Rows
    ],

    file:write_file(Path, [Header, Body]).


write_operation_csv(Path, Rows) ->
    Header =
        "users,repetition,operation,attempted,successful,failed\n",

    Body = lists:append([
        operation_csv_rows(Row)
        || Row <- Rows
    ]),

    file:write_file(Path, [Header, Body]).


operation_csv_rows(Row) ->
    Stats = maps:get(operation_stats, Row, #{}),

    [
        io_lib:format("~B,~B,~s,~B,~B,~B~n", [
            maps:get(users, Row),
            maps:get(repetition, Row),
            atom_to_list(Operation),
            maps:get(attempted, Counts, 0),
            maps:get(successful, Counts, 0),
            maps:get(failed, Counts, 0)
        ])
        || {Operation, Counts} <- lists:sort(
            maps:to_list(Stats)
        )
    ].
