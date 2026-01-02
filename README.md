# Future::IO::Redis - Sketch

Non-blocking Redis client using Future::IO (event-loop agnostic).

## Status

**SKETCH** - Proof of concept, not production ready.

## Test Results

```
t/01-basic.t ........ ok (8 tests - connect, ping, set/get, incr, lists, null)
t/02-nonblocking.t .. ok (4 tests - parallel, pipelining, event loop, pool)

Key metrics:
- Pipeline speedup: 8.1x (10 ops pipelined vs sequential)
- Timer ran during Redis ops (proves non-blocking I/O)
- Connection pool: 1.3ms for parallel operations
```

## Dependencies

```bash
cpanm Future::IO Future::AsyncAwait Protocol::Redis IO::Async
# Optional for performance:
cpanm Protocol::Redis::XS
```

## Running Tests

```bash
# Start Redis
docker compose up -d

# Wait for Redis to be ready
docker compose exec redis redis-cli ping

# Run tests
REDIS_HOST=localhost prove -lv t/

# Stop Redis
docker compose down
```

## What This Proves

1. **Future::IO has enough primitives** - `connect`, `ready_for_read`, `ready_for_write` are sufficient for TCP clients

2. **Protocol::Redis does the heavy lifting** - RESP parsing/encoding already exists

3. **Non-blocking is achievable** - Tests prove concurrent operations, timer interleaving, pipelining speedup

4. **~300 lines of code** - Not the 500-800 I estimated; Protocol::Redis makes it trivial

## Key Findings

### What Works

- Basic commands (GET, SET, INCR, lists, etc.)
- Pipelining (significant speedup)
- PUB/SUB
- Multiple concurrent connections
- Event loop can do other work while waiting

### What's Missing (for production)

- Connection pooling
- Automatic reconnection
- TLS/SSL support
- Cluster support
- Sentinel support
- Lua scripting helpers
- Stream commands (XREAD, etc.)
- Full command coverage

## Architecture

```
┌─────────────────────────────────────┐
│         Future::IO::Redis           │
│  - Connection management            │
│  - Command methods (get, set, etc.) │
│  - Pipelining                       │
│  - PUB/SUB                          │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│         Protocol::Redis(::XS)       │
│  - RESP parsing                     │
│  - RESP encoding                    │
│  - Streaming/incremental            │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│            Future::IO               │
│  - ready_for_read/write             │
│  - Event loop abstraction           │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│  IO::Async / AnyEvent / UV / etc.   │
└─────────────────────────────────────┘
```

## Implications for PAGI-Channels

This sketch proves `PAGI::Channels::Backend::Redis` is feasible:

1. Use Future::IO::Redis (or similar) for Redis communication
2. Memory backend for v1 is still right (simpler, no external deps)
3. Redis backend could be v1.1 or v2 with minimal effort

The bottleneck is NOT Future::IO primitives - it's just that nobody has packaged this yet.
