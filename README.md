
# DOSP Project 4.1 — Reddit Clone Engine and Simulator

## Project Overview

An Erlang implementation of a Reddit-like social media engine and simulator.

The project uses Erlang processes and message passing to model independent clients communicating with a central engine process.

## Current Implementation

### Milestone 1 — Engine and Client Registration

- Central Reddit engine process
- Independent client actor processes
- Message-based client-to-engine communication
- Account registration
- Duplicate username rejection
- Basic username validation
- Concurrent registration simulator
- Registration throughput measurement
- EUnit tests

## Project Structure

```text
project4.1/
├── src/
│   ├── reddit_engine.erl
│   ├── reddit_client.erl
│   └── reddit_simulator.erl
├── test/
│   └── reddit_tests.erl
├── scripts/
│   └── performance_test.erl
├── results/
├── ebin/
├── Makefile
├── README.md
└── .gitignore
```

## Requirements

- Erlang/OTP
- `erl`
- `erlc`
- GNU Make

No external Erlang dependencies are required.

## Compile

```bash
make clean
make compile
```

## Run Tests

```bash
make test
```

## Run Simulator

```bash
make simulate
```

The default simulator run creates 100 client processes and submits concurrent registration requests.

## Planned Milestones

1. Engine, client actors, and account registration
2. Subreddit creation, joining, and leaving
3. Posts and user feeds
4. Comments and hierarchical replies
5. Upvotes, downvotes, and karma
6. Direct messages and replies
7. Zipf-based simulator and user connection/disconnection
8. Performance experiments, results, and final report
