# Reddit Clone Engine and Simulator

## Team Member
Pradhyuman Singh Shekhawat

UFID: 55742970 

## 1. Project Overview

This project implements the engine and client simulator for a Reddit-like application in Erlang. The scope is Part I of the assignment: an application engine and a simulator that exercises its functionality.

The implementation supports account registration, subreddit management, text posts, feeds, hierarchical comments, voting and karma, direct messages, and reposts. It also includes simulations of client connection and disconnection, Zipf-distributed subreddit membership, and workload performance.

## 2. Implemented Functionality

| Requirement | Implementation |
|---|---|
| Register accounts | Registers accounts and rejects duplicate usernames. |
| Create, join, and leave subreddits | Supports subreddit creation, membership changes, and membership information. The creator is automatically added as the first member. |
| Create text posts | Creates text-only posts in subreddits and restricts posting to members. |
| Hierarchical comments | Supports comments on posts and replies to comments at multiple nesting levels. Comments can be retrieved as a hierarchical tree. |
| Upvote, downvote, and karma | Supports voting on posts and comments, retrieves scores, and computes account karma from the user's content scores. |
| Retrieve post feeds | Retrieves posts from a user's joined subreddits in newest-first order. Posts from subreddits the user has left are excluded. |
| Direct messages | Supports sending messages, retrieving inbox and sent-message lists, retrieving conversations, and replying to messages. |
| Reposts | Supports reposting an existing post and retrieving a user's reposts. |

## 3. Architecture

The implementation separates client activity from engine state using Erlang processes.

- **Engine:** One central Erlang process owns the application state, including accounts, subreddits, posts, comments, votes, and messages. It receives client requests through message passing and processes them sequentially in its receive loop.
- **Clients:** Each simulated user is represented by an independent client process. Client operations are sent to the engine through the client interface.
- **Simulator:** The simulator creates one client process per simulated user and exercises the engine through those clients.

The full-workload simulator limits request submission to at most 16 in-flight operations. This bounds the number of outstanding requests; it does not limit the number of client processes. The engine remains a single process, consistent with the architecture specified in the assignment.

## 4. Simulator

The simulator provides a full application workload and a separate client lifecycle experiment.

### 4.1 Full application workload

The full workload exercises registration, subreddit creation and membership, post creation, reposts, comments, voting, feed retrieval, direct messages, and message replies.

**Subreddit membership distribution.** Each user is assigned to one subreddit using a deterministic inverse-CDF Zipf-style distribution. A subreddit of rank \(r\) receives weight \(1/r^s\), with a default exponent \(s=1.0\). The resulting distribution assigns more users to higher-ranked subreddits and fewer users to lower-ranked subreddits. The subreddit creator is already a member of the subreddit they create.

**Post activity.** The simulator calculates each user's post count using both the membership count of the user's assigned subreddit and a deterministic simulated audience-size value. The audience-size value is a workload parameter derived from the user's index; it is not a separately maintained follower graph. Popularity and audience bonuses are each capped, and the resulting post count is capped at six per user.

**Reposts.** Each simulated user attempts one repost from a post in their assigned subreddit. The simulator selects another member's post when one is available; if the user is the only member, it falls back to that user's own post.

### 4.2 Client connection and disconnection

The lifecycle simulation alternates clients between connected and disconnected periods. A disconnected client process remains alive, but rejects operations locally with an offline error rather than forwarding them to the engine. Reconnecting the client restores normal operation. The simulator records successful operations, offline rejections, connection transitions, and other failures.

## 5. Build, Test, and Execution

Run the commands from the project root. Erlang/OTP and `make` are required.

### Compile the project

```bash
make compile
```

### Run the test suite

```bash
make clean
make test
```

The final validation run completed with **62 passing EUnit tests**.

### Run the registration simulation

```bash
make simulate
```

This target runs the registration-only simulation with 100 independent client processes. It is not the full application workload.

### Run the client lifecycle simulation

```bash
make simulate-lifecycle
```

This target runs the online/offline lifecycle experiment with 100 clients using the default lifecycle configuration.

The lifecycle function can also be called with explicit settings from the Erlang shell:

```erlang
reddit_simulator:run_lifecycle(100, #{
    duration_ms => 5000,
    online_ms => 1000,
    offline_ms => 500,
    operation_interval_ms => 100
}).
```

### Run the full application workload

After compiling, run the full workload for a selected user count:

```bash
erl -noshell -pa ebin -eval 'reddit_simulator:run_workload(2000), halt().'
```

For 5,000 simulated users:

```bash
erl -noshell -pa ebin -eval 'reddit_simulator:run_workload(5000), halt().'
```

The full workload prints operation counts, failures, subreddit membership distribution, phase durations, feed-entry counts, and the maximum number of in-flight operations.

To save an individual run's output, redirect it to a file. For example:

```bash
erl -noshell -pa ebin -eval 'reddit_simulator:run_workload(5000), halt().' > results/full_workload_5000.txt
```

### Run the scripted benchmark

```bash
make benchmark
```

The benchmark script runs three repetitions at each of 25, 50, 100, 250, and 500 users. It writes `results/benchmark_summary.csv` and `results/benchmark_operations.csv`. The separate 2,000-user and 5,000-user measurements reported below were collected by running the full workload three times at each scale; they are recorded in the `final_optimized_*` result files.

## 6. Performance Evaluation

The full workload was measured in three runs at each of 2,000 and 5,000 simulated users. All six runs completed with zero failed operations.

| Users | Run | Elapsed time (s) | Successful operations | Failed operations | Throughput (operations/s) |
|---:|---:|---:|---:|---:|---:|
| 2,000 | 1 | 10.760 | 23,505 | 0 | 2,184.49 |
| 2,000 | 2 | 9.058 | 23,505 | 0 | 2,594.94 |
| 2,000 | 3 | 8.824 | 23,505 | 0 | 2,663.73 |
| **2,000** | **Mean** | **9.547** | **23,505** | **0** | **2,481.05** |
| 5,000 | 1 | 103.943 | 58,755 | 0 | 565.26 |
| 5,000 | 2 | 99.056 | 58,755 | 0 | 593.15 |
| 5,000 | 3 | 99.751 | 58,755 | 0 | 589.02 |
| **5,000** | **Mean** | **100.917** | **58,755** | **0** | **582.48** |

The 5,000-user workload used five subreddits with the following membership distribution:

| Subreddit | Members |
|---|---:|
| community_1 | 2,190 |
| community_2 | 1,097 |
| community_3 | 730 |
| community_4 | 549 |
| community_5 | 439 |

Each 5,000-user run returned 33,350,282 feed entries. Feed retrieval was the dominant workload phase, taking approximately 80.54–85.00 seconds per run. The measurements reflect the cost of processing a large feed workload through one sequential engine process.

The recorded environment was macOS 26.6.2 (arm64), with 8 CPU cores and 32 GiB of physical memory, using Erlang/OTP 29 (ERTS 17.1). The captured environment information is included in `results/environment.txt`.

## 7. Implementation Notes

Feed retrieval merges the already newest-first post-ID lists from subscribed subreddits using `gb_sets`, rather than concatenating and sorting the complete feed. The simulator also bounds outstanding workload requests, records per-phase timings and failure reasons, and stores feed-entry counts in benchmark summaries instead of retaining complete feed payloads.

## 8. Project Structure

```text
project4.1/
├── src/
│   ├── reddit_client.erl
│   ├── reddit_engine.erl
│   └── reddit_simulator.erl
├── test/
│   └── reddit_tests.erl
├── scripts/
│   └── performance_test.erl
├── results/
│   ├── environment.txt
│   ├── benchmark_summary.csv
│   ├── benchmark_operations.csv
│   ├── final_optimized_2000_users.txt
│   ├── final_optimized_2000_run_2.txt
│   ├── final_optimized_2000_run_3.txt
│   ├── final_optimized_5000_users.txt
│   ├── final_optimized_5000_run_2.txt
│   └── final_optimized_5000_run_3.txt
├── .gitignore
├── Makefile
└── README.md
```
