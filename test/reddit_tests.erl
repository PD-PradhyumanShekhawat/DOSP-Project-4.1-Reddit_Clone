
-module(reddit_tests).

-include_lib("eunit/include/eunit.hrl").

engine_start_test() ->
    Engine = reddit_engine:start_link(),
    try
        ?assert(is_pid(Engine)),
        ?assertEqual({ok, 0}, reddit_engine:account_count(Engine))
    after
        reddit_engine:stop(Engine)
    end.

single_registration_test() ->
    Engine = reddit_engine:start_link(),
    Client = reddit_client:start_link(Engine),

    try
        ?assertEqual(
            {ok, registered},
            reddit_client:register(Client, "alice")
        ),
        ?assertEqual({ok, 1}, reddit_engine:account_count(Engine))
    after
        reddit_client:stop(Client),
        reddit_engine:stop(Engine)
    end.

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
    Engine = reddit_engine:start_link(),
    Client = reddit_client:start_link(Engine),

    try
        ?assertEqual(
            {error, invalid_username},
            reddit_client:register(Client, "")
        ),
        ?assertEqual(
            {error, invalid_username},
            reddit_client:register(Client, "   ")
        ),
        ?assertEqual({ok, 0}, reddit_engine:account_count(Engine))
    after
        reddit_client:stop(Client),
        reddit_engine:stop(Engine)
    end.

concurrent_registration_test() ->
    Engine = reddit_engine:start_link(),
    Clients = [
        reddit_client:start_link(Engine)
        || _ <- lists:seq(1, 20)
    ],

    try
        Parent = self(),

        [
            spawn(fun() ->
                Username = "user_" ++ integer_to_list(Index),
                Result = reddit_client:register(Client, Username),
                Parent ! {registration_result, Result}
            end)
            || {Client, Index} <- lists:zip(
                Clients,
                lists:seq(1, length(Clients))
            )
        ],

        Results = collect_test_results(20, []),

        ?assertEqual(20, length([
            Result
            || Result <- Results,
               Result =:= {ok, registered}
        ])),

        ?assertEqual({ok, 20}, reddit_engine:account_count(Engine))
    after
        lists:foreach(
            fun(Client) -> reddit_client:stop(Client) end,
            Clients
        ),
        reddit_engine:stop(Engine)
    end.

simulator_test() ->
    Summary = reddit_simulator:run(25),

    ?assertEqual(25, maps:get(requested_users, Summary)),
    ?assertEqual(25, maps:get(successful_registrations, Summary)),
    ?assertEqual(0, maps:get(failed_registrations, Summary)),
    ?assertEqual({ok, 25}, maps:get(engine_account_count, Summary)).

collect_test_results(0, Results) ->
    Results;

collect_test_results(Remaining, Results) ->
    receive
        {registration_result, Result} ->
            collect_test_results(Remaining - 1, [Result | Results])
    after 10000 ->
        ?assert(false)
    end.
