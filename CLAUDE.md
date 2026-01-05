# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Start Redis for tests (from project root)
cd t && docker compose up -d && cd ..

# Run all tests
REDIS_HOST=localhost prove -l t/

# Run single test file
REDIS_HOST=localhost prove -l t/20-commands/strings.t

# Run test directory
REDIS_HOST=localhost prove -lr t/20-commands/

# Unit tests (no Redis needed)
prove -l t/01-unit/

# Verbose output
REDIS_HOST=localhost prove -lv t/01-basic.t

# Stop Redis
cd t && docker compose down
```

Build system: Dist::Zilla (`dzil build`, `dzil test`)

## Architecture

**Async Stack:**
```
Async::Redis → Protocol::Redis(::XS) → Future::IO → IO::Async/UV/AnyEvent
```

All I/O is non-blocking via `Future::AsyncAwait` syntax. Event loop agnostic through `Future::IO` abstraction.

**Core Modules:**
- `Async::Redis` - Main client, connection management, command dispatch
- `Async::Redis::Commands` - Auto-generated async methods for all Redis commands
- `Async::Redis::Pipeline` - Batch command execution
- `Async::Redis::Pool` - Connection pooling with health checks
- `Async::Redis::Transaction` - MULTI/EXEC/WATCH support
- `Async::Redis::Subscription` - PubSub with message iterator
- `Async::Redis::AutoPipeline` - Implicit batching within event loop tick
- `Async::Redis::KeyExtractor` - Key position mapping for prefix support

**Command Generation:**
```bash
bin/generate-commands --input share/commands.json --output lib/Async/Redis/Commands.pm
```
The `share/commands.json` contains Redis command specs; regenerate Commands.pm after updates.

## Test Helper Patterns

Tests use `t/lib/Test/Async/Redis.pm`. Key exports:

```perl
use Test::Lib;
use Test::Async::Redis ':redis';
use Test2::V0;

my $redis = skip_without_redis();  # Get connection or skip test

subtest 'example' => sub {
    my $result = run { $redis->get('key') };  # Execute async code
    is $result, 'expected', 'description';
};

cleanup_keys($redis, 'prefix:*');  # Clean up test keys
```

- `run { ... }` - Execute async block, return result
- `skip_without_redis()` - Returns connected client or skips
- `init_loop()` / `get_loop()` - Manage IO::Async event loop
- `redis_host()` / `redis_port()` - From REDIS_HOST/REDIS_PORT env vars

## Key Patterns

**Pipeline/Transaction:** Use AUTOLOAD to capture command calls, execute on `->execute()` or EXEC.

**Fork Safety:** Tracks `_pid`, invalidates connections on fork detection without closing parent's socket.

**Timeouts:** Deadline-based system; blocking commands (BLPOP, XREAD) get server timeout + buffer.

**Error Hierarchy:** `Async::Redis::Error::*` (Connection, Timeout, Disconnected, Protocol, Redis) with context.
