
## Current Implementation

### Milestone 1 — Engine and Client Registration
- Central Reddit engine process
- Independent client actor processes
- Message-based client-to-engine communication
- Account registration and duplicate username rejection
- Concurrent registration simulator
- Registration throughput measurement
- EUnit tests

### Milestone 2 — Subreddit Management
- Create subreddits
- Automatically add the creator as the first member
- Join existing subreddits
- Leave subreddits
- Prevent duplicate subreddit creation
- Prevent duplicate membership
- Validate account and subreddit existence
- Retrieve subreddit membership information

## Current Architecture

The central engine owns account and subreddit state.

Independent client processes send requests to the engine using Erlang message passing. The engine processes requests sequentially through its receive loop, ensuring that state changes are serialized.

## Testing

Run:

```bash
make clean
make test
```

## Simulation

Run:

```bash
make simulate
```

The default simulator creates 100 independent clients and measures concurrent account registration.
