# Missing Features from Future::IO

This document tracks features that would make building async Redis clients (and similar projects) easier if they existed in Future::IO.

## High Priority

### 1. Connection Lifecycle Events

**Problem:** No built-in way to get notified when a connection is established, disconnected, or errors occur at the socket level.

**Current Workaround:** Manual tracking with wrapper code.

**Desired API:**
```perl
my $conn = Future::IO->connect($socket, $addr,
    on_connect    => sub { ... },
    on_disconnect => sub { ... },
    on_error      => sub { ... },
);
```

### 2. Non-blocking TLS Upgrade

**Problem:** `IO::Socket::SSL->start_SSL()` is blocking. There's no clean async path for upgrading a plain socket to TLS after connection.

**Current Workaround:** Use IO::Async::SSL or handle at socket creation time.

**Desired API:**
```perl
await Future::IO->start_tls($socket, %ssl_options);
```

### 3. Read with Timeout

**Problem:** `Future::IO->read()` doesn't accept a timeout directly. Must compose with `->timeout()` externally.

**Current Workaround:**
```perl
my $data = await Future::IO->read($socket, $len)->timeout($secs);
```

**Desired API:**
```perl
my $data = await Future::IO->read($socket, $len, timeout => 5);
```

### 4. Write with Timeout

**Problem:** Same as read - no built-in timeout for write operations.

**Desired API:**
```perl
await Future::IO->write_exactly($socket, $data, timeout => 5);
```

## Medium Priority

### 5. Later/Next Tick Guarantee

**Problem:** `Future::IO->later` behavior varies by implementation. Sometimes it fires immediately, sometimes on next event loop iteration.

**Desired:** Documented, consistent "run on next event loop tick" behavior across all implementations.

### 6. Connection Pooling Primitives

**Problem:** No standard primitives for connection state tracking (connected, idle, busy).

**Desired API:**
```perl
my $state = Future::IO->connection_state($socket);
# Returns: 'connected', 'disconnecting', 'closed', 'error'
```

### 7. Buffered Reader

**Problem:** Need to manually track read buffers when parsing protocols that may return partial data.

**Current Workaround:** Manual buffer in user code with parser callback.

**Desired API:**
```perl
my $reader = Future::IO->buffered_reader($socket);
my $line = await $reader->read_until("\r\n");
my $bytes = await $reader->read_exactly(1024);
```

## Low Priority

### 8. Unix Domain Socket Helper

**Problem:** Creating Unix domain sockets requires manual Socket.pm usage.

**Desired API:**
```perl
await Future::IO->connect_unix('/var/run/redis.sock');
```

### 9. Reconnection Helper

**Problem:** Reconnection with exponential backoff is common pattern, always reimplemented.

**Desired API:**
```perl
my $conn = await Future::IO->connect_with_retry(
    $socket, $addr,
    max_attempts => 5,
    backoff      => 'exponential',
    base_delay   => 0.1,
    max_delay    => 30,
);
```

### 10. Health Check Pattern

**Problem:** Periodic health checks on idle connections require manual timer setup.

**Desired API:**
```perl
Future::IO->watch_health($socket,
    interval => 30,
    check    => async sub { await ping() },
    on_fail  => sub { reconnect() },
);
```

---

## Notes

These observations come from building Future::IO::Redis, specifically:

- **Timeouts**: Every Redis operation needs timeout handling. Composing `->timeout()` externally works but is verbose.

- **Connection State**: Pool implementations need to know if a socket is still usable. Currently must track manually.

- **TLS**: Redis supports `STARTTLS` (via `redis://` to `rediss://` upgrade). Non-blocking TLS upgrade would help.

- **Buffering**: RESP protocol parsing requires buffered reads. Currently implemented in Protocol::Redis, but a general-purpose buffered reader would be useful.

- **Event Loop Tick**: Auto-pipelining relies on "flush on next tick" semantics. Consistent behavior across implementations would be helpful.
