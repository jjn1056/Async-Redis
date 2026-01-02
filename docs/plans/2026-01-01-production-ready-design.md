# Future::IO::Redis Production-Ready Design

**Date:** 2026-01-01
**Status:** Approved

---

## Overview

Design for making Future::IO::Redis a production-ready, rock-solid Redis client. Key goals:

1. **Full command coverage** - Auto-generate from Redis specs (Net::Async::Redis style)
2. **API compatibility** - Match Net::Async::Redis naming conventions
3. **Bulletproof reliability** - Handle connection drops, timeouts, and data integrity
4. **PAGI-Channels ready** - PubSub and connection pooling for channel layer backend

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Command coverage | Auto-generate from redis-doc JSON | Matches Net::Async::Redis, stays current with Redis releases |
| Method naming | snake_case (`cluster_addslots`) | Net::Async::Redis compatibility |
| Error handling | Typed exception classes | Clear failure categories, catchable |
| Reconnection | Automatic with exponential backoff | Production resilience |
| TLS | IO::Socket::SSL (optional dep) | Standard Perl TLS solution |

---

## Section 1: Connection Management

### Constructor Options

```perl
my $redis = Future::IO::Redis->new(
    host              => 'localhost',
    port              => 6379,

    # Or Unix socket
    path              => '/var/run/redis.sock',

    # Or connection URI (overrides host/port/path)
    uri               => 'redis://user:pass@localhost:6379/2',
    uri               => 'rediss://localhost:6380/0',  # TLS
    uri               => 'redis+unix:///var/run/redis.sock?db=1',

    # Timeouts (seconds)
    connect_timeout   => 10,
    read_timeout      => 30,
    write_timeout     => 30,

    # Reconnection
    reconnect         => 1,           # enable auto-reconnect
    reconnect_delay   => 0.1,         # initial delay
    reconnect_delay_max => 60,        # max delay (exponential backoff)
    reconnect_jitter  => 0.25,        # randomization factor

    # Events
    on_connect    => sub { my ($redis) = @_; ... },
    on_disconnect => sub { my ($redis, $reason) = @_; ... },
    on_error      => sub { my ($redis, $error) = @_; ... },

    # Queue management
    queue_size        => 1000,      # max commands queued during reconnect

    # Connection identification
    client_name       => 'myapp',   # CLIENT SETNAME on connect

    # Key prefixing (namespace isolation)
    prefix            => 'myapp:',  # auto-prepend to all keys

    # Performance tuning
    read_buffer_size  => 65536,     # socket read buffer (default 64KB)
    write_buffer_size => 65536,     # socket write buffer (default 64KB)
    pipeline_depth    => 100,       # max pipelined commands before flush
);
```

### Behavior

- Commands during disconnect get queued (up to `queue_size` limit)
- On reconnect, AUTH/SELECT replayed automatically
- Exponential backoff: 0.1s -> 0.2s -> 0.4s -> ... -> 60s max
- Jitter prevents thundering herd when many clients reconnect
- `on_disconnect` fires with reason: `connection_lost`, `timeout`, `server_closed`
- Key prefixing applied transparently to all key arguments
- Fork safety: detect PID change and create fresh connections (for prefork servers)

### Auto-Pipelining

```perl
my $redis = Future::IO::Redis->new(
    auto_pipeline => 1,  # enable auto-pipelining
);

# Commands issued in same event loop tick are batched automatically
my @futures = map { $redis->get("key$_") } (1..100);
my @values = await Future->all(@futures);
# Only 1 network round-trip instead of 100
```

When `auto_pipeline` enabled:
- Commands queued until event loop yields
- All queued commands sent as single pipeline
- Responses distributed to original Futures
- Transparent to caller - same API as non-pipelined

### Retry Strategies

```perl
my $redis = Future::IO::Redis->new(
    # Built-in strategies
    retry => 'exponential',     # default: exponential backoff

    # Or custom retry logic
    retry => sub {
        my ($attempt, $error, $command) = @_;
        return 0 if $attempt > 5;           # give up after 5 tries
        return 0 if $error->is_fatal;       # don't retry fatal errors
        return 0 if $command eq 'SET';      # don't retry writes
        return 0.1 * (2 ** $attempt);       # delay in seconds
    },
);
```

Retryable errors:
- Connection lost (reconnect first, then retry)
- Timeout (if idempotent command)
- LOADING (Redis still loading dataset)
- BUSY (script in progress)

Non-retryable:
- WRONGTYPE, OOM, NOSCRIPT, AUTH errors
- Write commands (unless explicitly marked idempotent)

### Timeout Implementation

```perl
# Wrap Future::IO calls with timeout
my $connect_f = Future::IO->connect($socket, $sockaddr)
    ->timeout($self->{connect_timeout});

my $read_f = Future::IO->read($socket, 65536)
    ->timeout($self->{read_timeout});
```

---

## Section 2: Error Handling & Data Integrity

### Exception Classes

```perl
Future::IO::Redis::Error::Connection   # connect failed, connection lost
Future::IO::Redis::Error::Timeout      # read/write/connect timeout
Future::IO::Redis::Error::Protocol     # malformed RESP, unexpected response
Future::IO::Redis::Error::Redis        # Redis error response (WRONGTYPE, OOM, etc.)
Future::IO::Redis::Error::Disconnected # command issued while disconnected (queue full)
```

### Hierarchy

```
Future::IO::Redis::Error (base)
├── ::Connection
├── ::Timeout
├── ::Protocol
├── ::Redis
└── ::Disconnected
```

### Data Integrity Guarantees

1. **Command-response pairing** - Each command gets a unique ID internally. Responses matched strictly. Mismatch = protocol error, connection reset.

2. **Pipeline safety** - Pipeline commands sent atomically (single write). Responses read in order. Partial failure = entire pipeline fails.

3. **No silent failures** - Every command returns a Future that either resolves with data or fails with typed exception. Never hangs indefinitely (timeouts).

4. **Reconnect safety** - Commands in-flight when connection drops fail with `Connection` error. Only queued (not-yet-sent) commands retry on reconnect.

5. **PubSub isolation** - Subscribe mode uses dedicated connection state. Regular commands on subscriber connection produce error.

### Usage Pattern

```perl
$redis->get('key')->on_fail(sub {
    my ($error) = @_;
    if ($error->isa('Future::IO::Redis::Error::Timeout')) {
        # handle timeout
    } elsif ($error->isa('Future::IO::Redis::Error::Redis')) {
        # handle Redis error (WRONGTYPE, etc.)
    }
});

# Or with try/catch
use Syntax::Keyword::Try;

try {
    my $value = await $redis->get('key');
} catch ($e) {
    warn "Redis error: $e";
}
```

---

## Section 3: Authentication & TLS

### Constructor Options

```perl
my $redis = Future::IO::Redis->new(
    host => 'redis.example.com',
    port => 6380,

    # Authentication
    password => 'secret',              # Redis < 6 (AUTH password)
    username => 'myuser',              # Redis 6+ ACL (AUTH username password)

    # Database selection
    database => 2,                     # SELECT 2 after connect

    # TLS - simple
    tls => 1,                          # enable with defaults

    # TLS - detailed
    tls => {
        ca_file   => '/path/to/ca.crt',
        cert_file => '/path/to/client.crt',
        key_file  => '/path/to/client.key',
        verify    => 1,                # verify server cert (default)
    },
);
```

### Connection Sequence

```
1. TCP connect (or Unix socket)
2. TLS upgrade (if tls => 1)
3. AUTH username password (if credentials provided)
4. SELECT database (if database specified)
5. CLIENT SETNAME (if client_name specified)
6. Connection ready
```

### URI Format

```
redis://[[username:]password@]host[:port][/database]
rediss://...                    # TLS enabled
redis+unix://[:password@]/path/to/socket[?db=N]
```

Examples:
- `redis://localhost` - defaults to port 6379, db 0
- `redis://:secret@localhost:6380/2` - password, custom port, db 2
- `rediss://user:pass@redis.example.com` - TLS with ACL auth
- `redis+unix:///var/run/redis.sock?db=1` - Unix socket

### Reconnect Behavior

- AUTH/SELECT replayed automatically on reconnect
- Same sequence as initial connect
- Credentials stored securely in object (not logged)

### Dependencies

- TLS requires IO::Socket::SSL (optional dependency)
- Without IO::Socket::SSL, `tls => 1` throws error at connect time

---

## Section 4: Pipelining

### Basic Pipeline API

```perl
# Build pipeline, execute all at once
my $pipe = $redis->pipeline;
$pipe->set('key1', 'value1');
$pipe->set('key2', 'value2');
$pipe->get('key1');
$pipe->incr('counter');

my $results = await $pipe->execute;
# $results = ['OK', 'OK', 'value1', 1]
```

### Chained Style

```perl
my $results = await $redis->pipeline
    ->set('a', 1)
    ->set('b', 2)
    ->get('a')
    ->get('b')
    ->execute;
```

### Error Handling

```perl
# Individual command errors don't fail the pipeline
my $results = await $redis->pipeline
    ->set('key', 'value')
    ->incr('key')           # WRONGTYPE error
    ->get('key')
    ->execute;

# $results = ['OK', Error::Redis->new(...), 'value']
# Check each result for errors
```

### Behavior

- Commands queued locally until `execute` called
- All commands sent in single write (atomic network operation)
- Responses collected in order
- Individual command errors captured, don't abort pipeline
- Pipeline object is single-use (cannot re-execute)

---

## Section 5: Transactions

### Basic Transaction

```perl
my $results = await $redis->multi(async sub {
    my ($tx) = @_;
    $tx->incr('counter');
    $tx->get('counter');
    $tx->set('updated', time());
});
# $results = [1, '1', 'OK']
```

### WATCH for Optimistic Locking

```perl
# Watch keys, abort if they change before EXEC
my $results = await $redis->watch_multi(['balance'], async sub {
    my ($tx, $watched) = @_;

    # $watched contains current values of watched keys
    my $balance = $watched->{balance};

    if ($balance >= 100) {
        $tx->decrby('balance', 100);
        $tx->incr('purchases');
    }
});

# Returns undef if WATCH failed (key changed)
# Returns results array if successful
```

### Manual Transaction Control

```perl
await $redis->watch('key1', 'key2');
await $redis->multi;
await $redis->incr('key1');
await $redis->decr('key2');
my $results = await $redis->exec;  # undef if watch failed
await $redis->unwatch;             # clear watches
```

### Behavior

- MULTI queues commands server-side
- EXEC executes atomically
- WATCH enables optimistic locking
- DISCARD aborts transaction
- Nested transactions not supported (Redis limitation)

---

## Section 6: Lua Scripting

### EVAL

```perl
my $result = await $redis->eval(
    'return redis.call("GET", KEYS[1])',
    1,           # number of keys
    'mykey',     # KEYS[1]
);
```

### EVALSHA with Auto-Fallback

```perl
# Load script, get SHA
my $sha = await $redis->script_load($lua_code);

# Execute by SHA (faster, less bandwidth)
my $result = await $redis->evalsha($sha, 1, 'mykey');

# Auto-fallback: tries SHA, falls back to EVAL if NOSCRIPT
my $result = await $redis->evalsha_or_eval(
    $sha,
    $lua_code,
    1,
    'mykey'
);
```

### Script Object Pattern

```perl
# Define reusable script
my $script = $redis->script(<<'LUA');
    local current = redis.call('GET', KEYS[1]) or 0
    local new = current + ARGV[1]
    redis.call('SET', KEYS[1], new)
    return new
LUA

# Execute (auto-loads SHA on first use)
my $result = await $script->call('counter', 10);
```

---

## Section 7: Blocking Commands

### BLPOP / BRPOP

```perl
# Block up to 30 seconds for item
my $result = await $redis->blpop('queue', 30);
# $result = ['queue', 'item'] or undef on timeout

# Multiple queues (priority order)
my $result = await $redis->blpop('high', 'medium', 'low', 10);
```

### Timeout Handling

```perl
# Blocking commands use their own timeout, not read_timeout
# The Redis timeout (last arg) controls server-side blocking
# Client adds small buffer to avoid race conditions

my $redis = Future::IO::Redis->new(
    read_timeout => 30,
    blocking_timeout_buffer => 2,  # extra seconds for blocking commands
);

# blpop('queue', 60) uses 62 second client timeout
```

### BRPOPLPUSH / BLMOVE

```perl
my $item = await $redis->brpoplpush('src', 'dst', 30);
my $item = await $redis->blmove('src', 'dst', 'RIGHT', 'LEFT', 30);
```

---

## Section 8: SCAN Iterators

### Basic SCAN

```perl
# Returns iterator object
my $iter = $redis->scan_iter(match => 'user:*', count => 100);

while (my $keys = await $iter->next) {
    for my $key (@$keys) {
        say $key;
    }
}
```

### HSCAN / SSCAN / ZSCAN

```perl
# Hash fields
my $iter = $redis->hscan_iter('myhash', match => 'field:*');
while (my $pairs = await $iter->next) {
    my %batch = @$pairs;  # field => value pairs
}

# Set members
my $iter = $redis->sscan_iter('myset', match => 'prefix:*');

# Sorted set members with scores
my $iter = $redis->zscan_iter('myzset', match => '*');
while (my $pairs = await $iter->next) {
    # [member, score, member, score, ...]
}
```

### Iterator Behavior

- Cursor managed internally
- Returns batches (not individual items)
- `next` returns undef when iteration complete
- Safe to use during key modifications
- `count` is hint, not guarantee

---

## Section 9: PubSub

### Subscribe API

```perl
# Subscribe returns a Subscription object
my $sub = await $redis->subscribe('channel1', 'channel2');

# Async iterator pattern
while (my $msg = await $sub->next) {
    say "Channel: $msg->{channel}";
    say "Message: $msg->{data}";
}

# Pattern subscribe
my $sub = await $redis->psubscribe('news:*', 'alerts:*');

while (my $msg = await $sub->next) {
    say "Pattern: $msg->{pattern}";   # 'news:*'
    say "Channel: $msg->{channel}";   # 'news:sports'
    say "Message: $msg->{data}";
}
```

### Unsubscribe

```perl
await $sub->unsubscribe('channel1');  # partial unsubscribe
await $sub->unsubscribe;              # all channels, ends iterator
```

### Publish

```perl
# Publish works on any connection (not subscription)
my $num_receivers = await $redis->publish('channel1', 'hello');
```

### Design Decisions

1. **Subscription is modal** - Once subscribed, connection only accepts SUBSCRIBE/UNSUBSCRIBE/PING/PSUBSCRIBE/PUNSUBSCRIBE. Other commands produce error.

2. **Separate connection recommended** - For apps needing both PubSub and regular commands:
   ```perl
   my $redis = Future::IO::Redis->new(...);      # commands
   my $pubsub = Future::IO::Redis->new(...);     # subscriptions
   ```

3. **Reconnect replays subscriptions** - On reconnect, automatically re-subscribes to all active channels/patterns.

4. **Message structure:**
   ```perl
   {
       type    => 'message',      # or 'pmessage', 'smessage'
       channel => 'news:sports',
       pattern => 'news:*',       # only for pmessage
       data    => 'payload',
   }
   ```

### Sharded PubSub (Redis 7+)

```perl
# Sharded subscribe - messages stay within cluster shard
my $sub = await $redis->ssubscribe('channel1', 'channel2');

while (my $msg = await $sub->next) {
    say "Sharded message: $msg->{data}";
}

# Sharded publish
my $num = await $redis->spublish('channel1', 'hello');
```

- Uses SSUBSCRIBE/SPUBLISH instead of SUBSCRIBE/PUBLISH
- Messages routed to shard owning the channel's slot
- Better scalability in Redis Cluster deployments
- Reconnect replays sharded subscriptions too

---

## Section 5: Connection Pool

### Constructor

```perl
my $pool = Future::IO::Redis::Pool->new(
    host     => 'localhost',
    port     => 6379,

    # Pool sizing
    min      => 2,          # keep 2 connections warm
    max      => 10,         # max concurrent connections

    # Timeouts
    acquire_timeout => 5,   # max wait for connection (seconds)
    idle_timeout    => 60,  # close idle connections after 60s

    # Pass through to connections
    password => 'secret',
    database => 1,
    tls      => 1,
);
```

### Usage Patterns

```perl
# Acquire/release pattern
my $redis = await $pool->acquire;
await $redis->set('foo', 'bar');
$pool->release($redis);

# Scoped pattern (auto-release, safer)
my $result = await $pool->with(async sub {
    my ($redis) = @_;
    await $redis->incr('counter');
});
```

### Pool Statistics

```perl
my $stats = $pool->stats;
# Returns:
# {
#     active  => 3,    # currently in use
#     idle    => 2,    # available in pool
#     waiting => 0,    # requests waiting for connection
#     total   => 5,    # active + idle
# }
```

### Behavior

- Connections created on demand up to `max`
- Idle connections beyond `min` closed after `idle_timeout`
- Health check (PING) before returning connection from pool
- Dead connections removed automatically
- `acquire_timeout` prevents indefinite blocking under load
- Connections inherit all settings (auth, tls, database)

---

## Section 6: Command Generation

### Build Process

```
┌─────────────────────────────────────────────────────────────────┐
│  redis-doc/commands.json  ──►  bin/generate-commands  ──►  Commands.pm  │
└─────────────────────────────────────────────────────────────────┘
```

### Source

Commands fetched from: https://github.com/redis/redis-doc/blob/master/commands.json

### Generated Output

```perl
# lib/Future/IO/Redis/Commands.pm (auto-generated)
package Future::IO::Redis::Commands;

use Future::AsyncAwait;

# String commands
async sub get { shift->command('GET', @_) }
async sub set { shift->command('SET', @_) }
async sub append { shift->command('APPEND', @_) }
async sub incr { shift->command('INCR', @_) }
async sub decr { shift->command('DECR', @_) }

# Multi-word commands become snake_case
async sub client_setname { shift->command('CLIENT', 'SETNAME', @_) }
async sub client_getname { shift->command('CLIENT', 'GETNAME', @_) }
async sub cluster_addslots { shift->command('CLUSTER', 'ADDSLOTS', @_) }
async sub config_get { shift->command('CONFIG', 'GET', @_) }
async sub config_set { shift->command('CONFIG', 'SET', @_) }

# Commands needing transformation
async sub hgetall {
    my $self = shift;
    my $arr = await $self->command('HGETALL', @_);
    return { @$arr };  # array -> hash
}

async sub info {
    my $self = shift;
    my $raw = await $self->command('INFO', @_);
    return _parse_info($raw);  # parse into hash
}

1;
```

### Method Naming Convention

| Redis Command | Perl Method |
|---------------|-------------|
| `GET` | `get` |
| `SET` | `set` |
| `CLIENT SETNAME` | `client_setname` |
| `CLUSTER ADDSLOTS` | `cluster_addslots` |
| `CONFIG GET` | `config_get` |
| `CLIENT NO-EVICT` | `client_no_evict` |

### Transformers

Some commands need return value transformation:

| Command | Transformation |
|---------|---------------|
| `HGETALL` | Array -> Hash |
| `INFO` | String -> Parsed Hash |
| `SCAN` | Array -> Iterator object |
| `HSCAN` | Array -> Iterator object |
| `TIME` | Array -> [seconds, microseconds] |

### Build Script Responsibilities

1. Fetch latest commands.json from redis-doc
2. Generate async method for each command
3. Apply transformers for special return types
4. Generate POD documentation per command
5. Track Redis version requirement for each command
6. Handle subcommands (CLIENT, CLUSTER, CONFIG, etc.)

---

## File Structure

```
lib/
├── Future/
│   └── IO/
│       ├── Redis.pm                    # Main client, uses Commands role
│       └── Redis/
│           ├── Commands.pm             # Auto-generated command methods
│           ├── Connection.pm           # Connection state machine
│           ├── Pool.pm                 # Connection pooling
│           ├── Pipeline.pm             # Command pipelining
│           ├── AutoPipeline.pm         # Automatic batching
│           ├── Transaction.pm          # MULTI/EXEC wrapper
│           ├── Subscription.pm         # PubSub subscription object
│           ├── Script.pm               # Lua script wrapper
│           ├── Iterator.pm             # SCAN cursor iterator
│           ├── URI.pm                  # Connection string parser
│           ├── Telemetry.pm            # OpenTelemetry integration
│           ├── Error.pm                # Exception base class
│           └── Error/
│               ├── Connection.pm
│               ├── Timeout.pm
│               ├── Protocol.pm
│               ├── Redis.pm
│               └── Disconnected.pm
bin/
└── generate-commands                   # Build script for Commands.pm
share/
└── commands.json                       # Cached Redis command specs
```

---

## Dependencies

### Required

- `Future` (core futures)
- `Future::AsyncAwait` (async/await syntax)
- `Future::IO` 0.17+ (async I/O primitives)
- `Protocol::Redis` or `Protocol::Redis::XS` (RESP parsing)

### Optional

- `IO::Socket::SSL` (TLS support)
- `Protocol::Redis::XS` (faster parsing)

### Development

- `Test2::V0` (testing)
- `Docker` / `docker-compose` (Redis instance for tests)

---

## Implementation Phases

### Phase 1: Core Reliability
- Timeouts (connect, read, write)
- Error exception classes
- Typed error handling
- URI connection strings
- Unix socket support

### Phase 2: Reconnection
- Automatic reconnect with backoff
- Connection events (on_connect, on_disconnect)
- Command queuing during reconnect
- CLIENT SETNAME on connect

### Phase 3: Security
- AUTH (password and username/password)
- SELECT database
- TLS support

### Phase 4: Command Generation
- Build script to generate Commands.pm
- Full command coverage from redis-doc
- Transformers for special commands

### Phase 5: Advanced Features
- Pipelining (already sketched, refine)
- Transactions (MULTI/EXEC/WATCH)
- Lua scripting (EVAL/EVALSHA/Script objects)
- Blocking command handling
- SCAN iterators

### Phase 6: Connection Pool
- Pool management (min/max/idle)
- Acquire/release pattern
- Health checking

### Phase 7: Observability
- OpenTelemetry tracing hooks
- Metrics collection
- Debug logging

### Phase 8: Testing & Polish
- Full test suite (see Section 15)
- Edge case handling
- Documentation
- CPAN release

---

## Section 15: Testing Strategy

### Test Categories

```
t/
├── 00-compile.t              # Module compilation
├── 01-unit/                  # Unit tests (no Redis needed)
│   ├── uri.t                 # URI parsing
│   ├── protocol.t            # RESP encoding/decoding
│   ├── error.t               # Exception classes
│   └── commands-generated.t  # Generated command methods exist
├── 10-connection/            # Connection tests
│   ├── basic.t               # Connect, disconnect
│   ├── timeout.t             # Connect/read/write timeouts
│   ├── reconnect.t           # Auto-reconnection
│   ├── backoff.t             # Exponential backoff timing
│   ├── events.t              # on_connect, on_disconnect, on_error
│   ├── unix-socket.t         # Unix socket connections
│   ├── tls.t                 # TLS/SSL connections
│   ├── auth.t                # AUTH, ACL authentication
│   ├── select.t              # Database selection
│   └── fork-safety.t         # PID tracking after fork
├── 20-commands/              # Command tests
│   ├── strings.t             # GET, SET, INCR, APPEND, etc.
│   ├── lists.t               # LPUSH, RPOP, LRANGE, etc.
│   ├── sets.t                # SADD, SMEMBERS, SINTER, etc.
│   ├── sorted-sets.t         # ZADD, ZRANGE, ZRANK, etc.
│   ├── hashes.t              # HSET, HGET, HGETALL, etc.
│   ├── keys.t                # DEL, EXISTS, EXPIRE, TTL, etc.
│   ├── server.t              # INFO, CONFIG, DBSIZE, etc.
│   └── prefix.t              # Key prefixing for all types
├── 30-pipeline/              # Pipeline tests
│   ├── basic.t               # Pipeline execution
│   ├── chained.t             # Chained API style
│   ├── errors.t              # Per-command error handling
│   ├── large.t               # 1000+ commands in pipeline
│   ├── auto-pipeline.t       # Automatic batching
│   └── depth-limit.t         # Pipeline depth limits
├── 40-transactions/          # Transaction tests
│   ├── multi-exec.t          # Basic MULTI/EXEC
│   ├── watch.t               # WATCH/UNWATCH
│   ├── watch-conflict.t      # WATCH abort on key change
│   ├── discard.t             # DISCARD behavior
│   └── nested.t              # Nested transaction error
├── 50-pubsub/                # PubSub tests
│   ├── subscribe.t           # SUBSCRIBE, UNSUBSCRIBE
│   ├── psubscribe.t          # Pattern subscribe
│   ├── publish.t             # PUBLISH
│   ├── multi-channel.t       # Multiple channels
│   ├── reconnect.t           # Subscription replay on reconnect
│   ├── sharded.t             # SSUBSCRIBE/SPUBLISH (Redis 7+)
│   └── isolation.t           # Commands on subscriber error
├── 60-scripting/             # Lua scripting tests
│   ├── eval.t                # EVAL
│   ├── evalsha.t             # EVALSHA
│   ├── script-load.t         # SCRIPT LOAD
│   ├── auto-fallback.t       # EVALSHA->EVAL fallback
│   └── script-object.t       # Script wrapper pattern
├── 70-blocking/              # Blocking command tests
│   ├── blpop.t               # BLPOP/BRPOP
│   ├── blmove.t              # BLMOVE
│   ├── timeout.t             # Blocking timeout handling
│   └── concurrent.t          # Multiple blocking waiters
├── 80-scan/                  # SCAN iterator tests
│   ├── scan.t                # SCAN
│   ├── hscan.t               # HSCAN
│   ├── sscan.t               # SSCAN
│   ├── zscan.t               # ZSCAN
│   ├── match.t               # Pattern matching
│   └── large.t               # 10000+ keys iteration
├── 90-pool/                  # Connection pool tests
│   ├── basic.t               # Acquire/release
│   ├── scoped.t              # with() pattern
│   ├── sizing.t              # min/max sizing
│   ├── idle.t                # Idle timeout
│   ├── health.t              # Health check on acquire
│   ├── concurrent.t          # Concurrent access
│   └── exhaustion.t          # Pool exhaustion, acquire_timeout
├── 91-reliability/           # Reliability tests
│   ├── redis-restart.t       # Survive Redis restart
│   ├── network-partition.t   # Connection drops mid-command
│   ├── slow-commands.t       # Timeout during slow command
│   ├── memory-pressure.t     # Redis OOM behavior
│   ├── queue-overflow.t      # Command queue limits
│   └── retry.t               # Retry strategy behavior
├── 92-concurrency/           # Concurrency tests
│   ├── parallel-commands.t   # Many concurrent commands
│   ├── parallel-pipelines.t  # Concurrent pipelines
│   ├── parallel-pubsub.t     # Concurrent pub/sub
│   ├── mixed-workload.t      # Commands + pipelines + pubsub
│   └── event-loop.t          # Non-blocking verification
├── 93-binary/                # Binary data tests
│   ├── binary-keys.t         # Binary key names
│   ├── binary-values.t       # Binary values (null bytes)
│   ├── utf8.t                # UTF-8 encoding
│   └── large-values.t        # 1MB+ values
├── 94-observability/         # Observability tests
│   ├── tracing.t             # OpenTelemetry spans
│   ├── metrics.t             # Metrics collection
│   └── debug.t               # Debug logging
└── 99-integration/           # Full integration tests
    ├── pagi-channels.t       # PAGI-Channels use case
    ├── high-throughput.t     # 10000+ ops/sec sustained
    ├── long-running.t        # 1 hour stability test
    └── redis-versions.t      # Redis 6, 7, 8 compatibility
```

### Test Infrastructure

#### Docker Compose for Redis

```yaml
# docker-compose.yml
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: redis-server --appendonly yes

  redis-tls:
    image: redis:7-alpine
    ports:
      - "6380:6380"
    volumes:
      - ./certs:/certs:ro
    command: >
      redis-server
      --port 0
      --tls-port 6380
      --tls-cert-file /certs/server.crt
      --tls-key-file /certs/server.key
      --tls-ca-cert-file /certs/ca.crt

  redis-auth:
    image: redis:7-alpine
    ports:
      - "6381:6381"
    command: redis-server --port 6381 --requirepass testpass

  redis-acl:
    image: redis:7-alpine
    ports:
      - "6382:6382"
    command: >
      redis-server --port 6382
      --user testuser on >testpass ~* +@all

  redis-sentinel:
    image: redis:7-alpine
    ports:
      - "26379:26379"
    depends_on:
      - redis
    # Sentinel config here

  redis-cluster:
    # 6-node cluster setup
```

#### Test Helpers

```perl
# t/lib/Test/Future/IO/Redis.pm
package Test::Future::IO::Redis;

use strict;
use warnings;
use Test2::V0;
use Future::IO::Redis;

# Skip if no Redis available
sub skip_without_redis {
    my $redis = eval {
        Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        )->connect->get;
    };
    return $redis if $redis;
    skip_all("Redis not available: $@");
}

# Clean up test keys
sub cleanup_keys {
    my ($redis, $pattern) = @_;
    my $keys = $redis->keys($pattern)->get;
    $redis->del(@$keys)->get if @$keys;
}

# Test with timeout wrapper
sub with_timeout {
    my ($timeout, $code) = @_;
    my $f = $code->();
    return $f->timeout($timeout);
}

# Assert Future fails with specific error type
sub fails_with {
    my ($future, $error_class, $message) = @_;
    my $error;
    eval { $future->get };
    $error = $@;
    ok($error && $error->isa($error_class), $message);
}

1;
```

### Test Scenarios

#### Reliability Tests

```perl
# t/91-reliability/redis-restart.t

use Test2::V0;
use Test::Future::IO::Redis;

my $redis = skip_without_redis();

subtest 'survives redis restart' => sub {
    # Set up reconnection
    my $disconnects = 0;
    my $reconnects = 0;

    $redis = Future::IO::Redis->new(
        host => 'localhost',
        reconnect => 1,
        on_disconnect => sub { $disconnects++ },
        on_connect => sub { $reconnects++ },
    );
    await $redis->connect;

    # Store value
    await $redis->set('test:key', 'before');

    # Simulate Redis restart (need Docker control)
    system('docker-compose restart redis');
    sleep(2);  # Wait for restart

    # Command should work after reconnect
    my $value = await $redis->get('test:key');
    is($value, 'before', 'value survives restart');
    is($disconnects, 1, 'disconnect detected');
    is($reconnects, 2, 'reconnected (initial + after restart)');
};

done_testing;
```

#### Concurrency Tests

```perl
# t/92-concurrency/parallel-commands.t

use Test2::V0;
use Test::Future::IO::Redis;
use Future;
use Time::HiRes qw(time);

my $redis = skip_without_redis();

subtest 'parallel commands are truly parallel' => sub {
    my $count = 100;

    # Sequential timing
    my $seq_start = time();
    for my $i (1..$count) {
        await $redis->set("seq:$i", $i);
    }
    my $seq_time = time() - $seq_start;

    # Parallel timing
    my $par_start = time();
    my @futures = map {
        $redis->set("par:$_", $_)
    } (1..$count);
    await Future->all(@futures);
    my $par_time = time() - $par_start;

    # Parallel should be significantly faster
    ok($par_time < $seq_time / 2,
        "parallel ($par_time) < sequential/2 ($seq_time/2)");
};

subtest 'event loop not blocked during commands' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    # Run slow command
    await $redis->debug_sleep(0.1);  # 100ms sleep

    $timer->stop;
    $loop->remove($timer);

    # Should have ~10 ticks during the sleep
    ok(@ticks >= 5, "timer ticked " . scalar(@ticks) . " times during Redis sleep");
};

done_testing;
```

#### Edge Case Tests

```perl
# t/93-binary/binary-values.t

use Test2::V0;
use Test::Future::IO::Redis;

my $redis = skip_without_redis();

subtest 'null bytes in values' => sub {
    my $binary = "foo\x00bar\x00baz";
    await $redis->set('binary:null', $binary);
    my $result = await $redis->get('binary:null');
    is($result, $binary, 'null bytes preserved');
};

subtest 'all byte values' => sub {
    my $all_bytes = pack("C*", 0..255);
    await $redis->set('binary:all', $all_bytes);
    my $result = await $redis->get('binary:all');
    is($result, $all_bytes, 'all 256 byte values preserved');
};

subtest 'binary keys' => sub {
    my $key = "key\x00with\xFFbinary";
    await $redis->set($key, 'value');
    my $result = await $redis->get($key);
    is($result, 'value', 'binary key works');
    await $redis->del($key);
};

subtest 'large binary value' => sub {
    my $large = pack("C*", map { $_ % 256 } (1..1_000_000));
    await $redis->set('binary:large', $large);
    my $result = await $redis->get('binary:large');
    is(length($result), 1_000_000, '1MB value preserved');
    is($result, $large, 'content matches');
};

done_testing;
```

### Coverage Requirements

| Category | Minimum Coverage |
|----------|------------------|
| Core modules | 95% |
| Commands.pm | 80% (generated) |
| Error paths | 90% |
| Edge cases | 85% |
| Overall | 90% |

### CI Pipeline

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        perl: ['5.18', '5.26', '5.34', '5.38']
        redis: ['6.2', '7.0', '7.2', '8.0']

    services:
      redis:
        image: redis:${{ matrix.redis }}-alpine
        ports:
          - 6379:6379

    steps:
      - uses: actions/checkout@v4
      - uses: shogo82148/actions-setup-perl@v1
        with:
          perl-version: ${{ matrix.perl }}

      - name: Install dependencies
        run: cpanm --installdeps --notest .

      - name: Run tests
        run: prove -l -j4 t/
        env:
          REDIS_HOST: localhost

      - name: Run coverage
        run: |
          cpanm Devel::Cover
          cover -test -report codecov

  stress-test:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      # ... setup ...
      - name: Run stress tests
        run: prove -l t/99-integration/
        timeout-minutes: 30

  tls-test:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - name: Generate certs
        run: ./scripts/generate-test-certs.sh
      - name: Start Redis with TLS
        run: docker-compose up -d redis-tls
      - name: Run TLS tests
        run: prove -l t/10-connection/tls.t
```

### Performance Benchmarks

```perl
# benchmark/throughput.pl

use Benchmark qw(:all);
use Future::IO::Redis;
use Net::Async::Redis;
use Mojo::Redis;

my $iterations = 10000;

cmpthese($iterations, {
    'Future::IO::Redis' => sub {
        # our implementation
    },
    'Net::Async::Redis' => sub {
        # comparison
    },
    'Mojo::Redis' => sub {
        # comparison
    },
});

# Target: within 20% of Net::Async::Redis performance
```

### Test Checklist

Before release, ALL must pass:

- [ ] All unit tests pass
- [ ] All integration tests pass with Redis 6.2, 7.0, 7.2, 8.0
- [ ] All tests pass on Perl 5.18, 5.26, 5.34, 5.38
- [ ] TLS tests pass
- [ ] Unix socket tests pass
- [ ] Fork safety tests pass
- [ ] 1-hour long-running test passes
- [ ] 10000 ops/sec throughput achieved
- [ ] Memory usage stable over long run
- [ ] No test flakiness (run 10x)
- [ ] Coverage >= 90%
- [ ] Benchmark within 20% of Net::Async::Redis

---

## Section 13: Observability

### OpenTelemetry Integration

```perl
use OpenTelemetry;

my $redis = Future::IO::Redis->new(
    host => 'localhost',

    # Enable tracing
    otel_tracer => OpenTelemetry->tracer_provider->tracer('redis'),

    # Enable metrics
    otel_meter => OpenTelemetry->meter_provider->meter('redis'),
);
```

### Traces

Each command creates a span:
```
Span: redis.GET
├── db.system: redis
├── db.operation: GET
├── db.statement: GET mykey
├── net.peer.name: localhost
├── net.peer.port: 6379
├── db.redis.database_index: 0
└── duration: 1.2ms
```

### Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `redis.commands.total` | Counter | Commands executed, by command name |
| `redis.commands.duration` | Histogram | Command latency |
| `redis.connections.active` | Gauge | Current active connections |
| `redis.connections.total` | Counter | Total connections created |
| `redis.reconnects.total` | Counter | Reconnection attempts |
| `redis.errors.total` | Counter | Errors by type |
| `redis.pipeline.size` | Histogram | Commands per pipeline |

### Debug Logging

```perl
my $redis = Future::IO::Redis->new(
    debug => 1,                    # log all commands
    debug => sub {                 # custom logger
        my ($direction, $data) = @_;
        # $direction: 'send' or 'recv'
        warn "[$direction] $data\n";
    },
);
```

---

## Section 14: Binary Data

Redis supports binary-safe strings. Future::IO::Redis handles this correctly:

```perl
# Binary keys and values work
my $binary = pack("C*", 0x00, 0x01, 0xFF, 0xFE);
await $redis->set($binary, $binary);
my $value = await $redis->get($binary);
# $value eq $binary

# UTF-8 strings auto-encoded
await $redis->set('key', 'こんにちは');  # UTF-8 encoded
my $text = await $redis->get('key');
# $text is bytes, decode if needed: decode('UTF-8', $text)
```

### Encoding Policy

- **Input**: Perl strings with UTF-8 flag → encoded to UTF-8 bytes
- **Input**: Byte strings → sent as-is
- **Output**: Always bytes (caller decodes if needed)
- **Keys**: Same rules as values

This matches Redis behavior: everything is bytes.

---

## Future Work (Post-1.0)

These features are explicitly out of scope for initial release but designed for:

### Sentinel Support

```perl
my $redis = Future::IO::Redis->new(
    sentinels => [
        'sentinel1.example.com:26379',
        'sentinel2.example.com:26379',
        'sentinel3.example.com:26379',
    ],
    service => 'mymaster',
);
```

- Query sentinels for master address
- Subscribe to failover notifications
- Automatic reconnect to new master

### Cluster Support

```perl
my $cluster = Future::IO::Redis::Cluster->new(
    nodes => ['node1:7000', 'node2:7001', 'node3:7002'],
);

await $cluster->set('foo', 'bar');  # routes to correct node
```

- Slot-based routing
- MOVED/ASK redirect handling
- Hash tags for co-location

### RESP3 Protocol

```perl
my $redis = Future::IO::Redis->new(
    protocol => 3,  # RESP3
);
```

- Better type information (maps, sets, booleans, nulls)
- Inline PubSub (no separate connection needed)
- Client-side caching invalidation via push notifications

---

## Success Criteria

1. **All tests pass** with real Redis instance
2. **No hangs** - every operation has timeout
3. **Graceful reconnect** - survives Redis restart
4. **PAGI-Channels works** - PubSub reliable under load
5. **API compatible** with Net::Async::Redis naming
6. **Full command coverage** - 200+ Redis commands auto-generated
7. **Transactions work** - MULTI/EXEC/WATCH atomic operations
8. **Pipelining efficient** - 8x+ speedup maintained
9. **TLS works** - secure connections to cloud Redis
10. **Pool works** - connection reuse under concurrent load
11. **Auto-pipelining works** - transparent batching
12. **Key prefixing works** - namespace isolation
13. **Fork-safe** - works with prefork servers (Starman, etc.)
14. **Binary-safe** - handles binary keys/values correctly
15. **Observable** - OpenTelemetry traces/metrics available
