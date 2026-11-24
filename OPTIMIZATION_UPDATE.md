# Reddit Engine Performance Update

This update changes three files:

- `src/reddit_engine.erl`: merges the already newest-first subreddit post-ID lists with `gb_sets` instead of concatenating and sorting the full feed.
- `src/reddit_simulator.erl`: limits task submission to 16 in-flight operations, records per-phase durations and failure reasons, and retains only feed-entry counts rather than full feed payloads in benchmark results.
- `test/reddit_tests.erl`: adds a regression test verifying newest-first ordering across multiple subscribed subreddits.

The engine remains a single process. The simulator still creates and retains one client process per simulated user. The concurrency limit applies only to the number of requests submitted to the engine at one time.

## Apply

Extract this archive into the root of the existing `project4.1` directory, allowing the three files to be overwritten. Keep a backup or commit before applying.

## Validate

```bash
make clean && make test
```

Then run the 2,000-user and 5,000-user workloads. Save outputs under `results/` and compare failures, throughput, and phase durations with the previous results.

The update has not been compiled or executed in this build environment because Erlang/OTP is not installed here. Compilation and EUnit validation must be performed in the project's Erlang environment before benchmarking.
