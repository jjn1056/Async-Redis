# Drop IO::Async Test Dependency Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace IO::Async test dependency with Future::IO 0.23's built-in poll-based default impl, fixing CPAN tester failures caused by Future::IO 0.22+ rejecting IOAsync via `load_impl`.

**Architecture:** Future::IO 0.23 ships a `_DefaultImpl` using `IO::Poll` (core Perl) that handles connect, read, write, sleep — everything Async::Redis needs. Tests use `$f->get` (which calls `$f->await` → `_await_once` → IO::Poll) instead of `$loop->await($f)`. Timer::Periodic non-blocking verification subtests are replaced with concurrent-futures timing tests.

**Tech Stack:** Future::IO 0.23 (default impl), IO::Poll (core), Time::HiRes (core)

---

## Patterns Reference

These patterns recur across tasks. Refer here instead of repeating.

### Pattern A: Replace `get_loop()->await($f)` calls

```perl
# OLD
get_loop()->await($f);

# NEW
$f->get;
```

### Pattern B: Replace `get_loop()->delay_future(after => N)`

```perl
# OLD
my $push_f = get_loop()->delay_future(after => 0.3)->then(async sub { ... });

# NEW
my $push_f = Future::IO->sleep(0.3)->then(async sub { ... });
```

### Pattern C: Replace `get_loop()->new_future`

```perl
# OLD
my $done = get_loop()->new_future;

# NEW
my $done = Future->new;
```

### Pattern D: Replace Timer::Periodic non-blocking subtests

```perl
# OLD
subtest 'non-blocking verification' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,
        on_tick => sub { push @ticks, 1 },
    );
    get_loop()->add($timer);
    $timer->start;

    # ... async work ...

    $timer->stop;
    get_loop()->remove($timer);
    ok(scalar @ticks > 0, "Event loop remained responsive");
};

# NEW
subtest 'non-blocking verification' => sub {
    # Concurrent operations prove non-blocking: if the impl were blocking,
    # needs_all would serialize and take N*RTT instead of ~1*RTT.
    my @futures = map { $redis->set("nb:$_", $_) } (1..50);
    my $start = Time::HiRes::time();
    run { Future->needs_all(@futures) };
    my $elapsed = Time::HiRes::time() - $start;

    ok($elapsed < 5, "50 concurrent ops completed in ${elapsed}s");

    run { $redis->del(map { "nb:$_" } 1..50) };
};
```

For blocking command tests (blpop/brpop/blmove) where we also need to prove the wait
doesn't block, we fire a concurrent sleep + the blocking command and verify both complete:

```perl
subtest 'non-blocking verification (CRITICAL)' => sub {
    run { $redis->del('nb:blpop:list') };

    # Schedule a push after delay — this only works if BLPOP doesn't block the loop
    my $push_f = Future::IO->sleep(0.3)->then(async sub {
        await $redis2->rpush('nb:blpop:list', 'delayed');
    });

    my $start = Time::HiRes::time();
    my $result = run { $redis->command('BLPOP', 'nb:blpop:list', 2) };
    my $elapsed = Time::HiRes::time() - $start;

    ok($elapsed < 1.5, "BLPOP resolved via delayed push (${elapsed}s), not timeout");
    is($result->[1], 'delayed', 'got the delayed value');

    run { $redis->del('nb:blpop:list') };
};
```

---

### Task 1: Update dependencies

**Files:**
- Modify: `cpanfile`

**Step 1: Update cpanfile**

```perl
# Runtime dependencies
requires 'perl', '5.018';
requires 'Future', '0.49';
requires 'Future::AsyncAwait', '0.66';
requires 'Future::IO', '0.23';          # was 0.19; need 0.23 for built-in poll impl
requires 'Protocol::Redis';
requires 'IO::Socket::INET';
requires 'Socket';
requires 'Time::HiRes';
requires 'Digest::SHA';

# Optional dependencies (for performance/features)
recommends 'Protocol::Redis::XS';  # Faster RESP parsing
recommends 'IO::Socket::SSL';      # TLS support
suggests 'OpenTelemetry::SDK';     # Observability integration

# Test dependencies
on 'test' => sub {
    requires 'Test2::V0';
    requires 'Test::Lib';
};

# Development dependencies
on 'develop' => sub {
    requires 'Dist::Zilla';
};
```

IO::Async, IO::Async::Timer::Periodic, IO::Async::Process, and Future::IO::Impl::IOAsync
are all removed from test deps.

**Step 2: Verify dist.ini still builds**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && dzil build 2>&1 | tail -5'`

**Step 3: Commit**

```
git add cpanfile
git commit -m "deps: bump Future::IO to 0.23, remove IO::Async test deps"
```

---

### Task 2: Rewrite test helper

**Files:**
- Modify: `t/lib/Test/Async/Redis.pm`

**Step 1: Rewrite the test helper**

Remove all IO::Async imports and loop management. The new test helper:

- Removes `use IO::Async::Loop`, `use IO::Async::Timer::Periodic`, `use IO::Async::Process`
- Removes `Future::IO->load_impl('IOAsync')` — default impl just works
- Removes the `$SIG{__WARN__}` handler (was for IO::Async cleanup warnings)
- Changes `run {}` to use `$f->get` instead of `get_loop()->await($f)`
- Changes `await_f($f)` to use `$f->get`
- Makes `init_loop()` return undef (kept for backward compat with tests that call it)
- Makes `get_loop()` return undef
- Removes `run_command`, `run_docker` (unused by any test)
- Replaces `measure_ticks` with a no-op or removes it (unused directly by tests;
  tests that had timer code used IO::Async::Timer::Periodic inline)
- Replaces `with_timeout` to use `Future::IO->sleep` instead of the loop

The key changes to `run` and `await_f`:
```perl
sub run (&) {
    my ($code) = @_;
    my $result = $code->();
    if (ref($result) && $result->isa('Future')) {
        return $result->get;  # .get calls .await internally
    }
    return $result;
}

sub await_f {
    my ($f) = @_;
    return $f->get;
}
```

Remove `init_loop` and `get_loop` from `@EXPORT_OK` and the `:redis` tag.
Remove the `init_loop()` call from `import()`.
Keep `_check_redis()` but update it to not use `init_loop()`.

**Step 2: Run unit tests (no Redis needed)**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/01-unit/ 2>&1'`
Expected: All pass (unit tests don't use test helper)

**Step 3: Run a simple integration test**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -lv t/01-basic.t 2>&1'`
Expected: PASS — this is the acid test for the new helper

**Step 4: Commit**

```
git add t/lib/Test/Async/Redis.pm
git commit -m "refactor: test helper uses Future::IO default impl instead of IO::Async"
```

---

### Task 3: Fix t/03-pubsub.t (heavy get_loop() usage)

**Files:**
- Modify: `t/03-pubsub.t`

This file uses `get_loop()->await($f)` on nearly every line. Apply Pattern A throughout.
Also apply Pattern C for `get_loop()->new_future` → `Future->new`.
Remove the `require Future::IO::Impl::IOAsync` on line 17.

All `get_loop()->await(...)` become `run { ... }` or just `... ->get`:

```perl
# OLD
get_loop()->await($pub->connect);
# NEW
$pub->connect->get;

# OLD
get_loop()->await(Future->needs_all($pub->connect, $sub->connect));
# NEW
Future->needs_all($pub->connect, $sub->connect)->get;

# OLD
$listeners = get_loop()->await($pub->publish('test:channel', 'message 1'));
# NEW
$listeners = $pub->publish('test:channel', 'message 1')->get;

# OLD
my $done = get_loop()->new_future;
# NEW
my $done = Future->new;
```

**Step 1: Apply replacements throughout t/03-pubsub.t**
**Step 2: Run test**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -lv t/03-pubsub.t 2>&1'`

**Step 3: Commit**

```
git add t/03-pubsub.t
git commit -m "test: remove IO::Async usage from pubsub test"
```

---

### Task 4: Fix t/10-connection tests

**Files:**
- Modify: `t/10-connection/timeout.t`
- Modify: `t/10-connection/tls.t`
- Modify: `t/10-connection/auth.t`
- Modify: `t/10-connection/fork-safety.t`
- Modify: `t/93-socket-cleanup/close-with-watchers.t`

**timeout.t:** Replace `get_loop()->await($f)` with `$f->get` (Pattern A).
Replace Timer::Periodic subtests with Pattern D concurrent-futures approach.

**tls.t:** Same — Pattern A for `get_loop()->await`, Pattern D for Timer.

**auth.t:** Pattern A for `get_loop()->await($f)`.

**fork-safety.t:** Line 46 creates `IO::Async::Loop->new` in child process for
`$child_loop->await(...)`. Replace with `$redis->get('fork:test')->get`.
Remove `use IO::Async::Loop` if it was imported directly.

**close-with-watchers.t:** Line 27 calls `init_loop()`. Since init_loop will return
undef (or be removed), just remove the call. The test uses `run {}` which still works.

**Step 1: Apply changes to all 5 files**
**Step 2: Run connection tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -l t/10-connection/ t/93-socket-cleanup/ 2>&1'`

**Step 3: Commit**

```
git add t/10-connection/ t/93-socket-cleanup/
git commit -m "test: remove IO::Async from connection and socket cleanup tests"
```

---

### Task 5: Fix blocking command tests (delay_future + Timer)

**Files:**
- Modify: `t/70-blocking/blpop.t`
- Modify: `t/70-blocking/brpop.t`
- Modify: `t/70-blocking/blmove.t`
- Modify: `t/70-blocking/concurrent.t`

These tests use two IO::Async features:
1. `get_loop()->delay_future(after => 0.3)` — schedule a delayed push (Pattern B)
2. `IO::Async::Timer::Periodic` — verify non-blocking behavior (Pattern D)

For the delayed push, replace with `Future::IO->sleep(0.3)->then(...)`.

For the non-blocking verification, these tests are critical because they prove
BLPOP/BRPOP/BLMOVE don't block the event loop. Replace with the blocking-specific
Pattern D variant that fires a concurrent delayed push + blocking command.

For `concurrent.t`: replace `get_loop()->delay_future(after => N)` with
`Future::IO->sleep(N)` (Pattern B).

**Step 1: Apply changes to all 4 files**
**Step 2: Run blocking tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -l t/70-blocking/ 2>&1'`

**Step 3: Commit**

```
git add t/70-blocking/
git commit -m "test: remove IO::Async from blocking command tests"
```

---

### Task 6: Fix Timer::Periodic in command/pipeline/scan/scripting/transaction tests

**Files (15 files, all same pattern):**
- Modify: `t/02-nonblocking.t`
- Modify: `t/20-commands/strings.t`
- Modify: `t/20-commands/sets.t`
- Modify: `t/20-commands/hashes.t`
- Modify: `t/20-commands/keys.t`
- Modify: `t/20-commands/lists.t`
- Modify: `t/20-commands/sorted-sets.t`
- Modify: `t/30-pipeline/basic.t`
- Modify: `t/30-pipeline/large.t`
- Modify: `t/30-pipeline/auto-pipeline.t`
- Modify: `t/40-transactions/multi-exec.t`
- Modify: `t/60-scripting/eval.t`
- Modify: `t/60-scripting/script-object.t`
- Modify: `t/80-scan/scan.t`
- Modify: `t/80-scan/large.t`

All 15 files have the same pattern: a "non-blocking verification" subtest using
`IO::Async::Timer::Periodic`. Replace all with Pattern D (concurrent futures timing).

Each file also has `use Time::HiRes qw(time)` or similar — ensure it's present for
the timing approach.

**Step 1: Apply Pattern D replacement to all 15 files**

Since the pattern is identical, this is mechanical: find the Timer::Periodic subtest
block in each file and replace with the concurrent futures version. Adjust the
key prefix and operation count to match what each test was originally doing.

**Step 2: Run all affected test directories**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -l t/02-nonblocking.t t/20-commands/ t/30-pipeline/ t/40-transactions/ t/60-scripting/ t/80-scan/ 2>&1'`

**Step 3: Commit**

```
git add t/02-nonblocking.t t/20-commands/ t/30-pipeline/ t/40-transactions/ t/60-scripting/ t/80-scan/
git commit -m "test: replace Timer::Periodic non-blocking subtests with concurrent futures"
```

---

### Task 7: Update examples and documentation

**Files:**
- Modify: `examples/slow-redis/app.pl` — replace `Future::IO->load_impl('IOAsync')` with
  `require Future::IO::Impl::IOAsync` (example still uses IOAsync, just avoids load_impl)
- Modify: `lib/Async/Redis.pm` (POD only) — update EVENT LOOP CONFIGURATION section:
  - Replace references to `load_impl` and `load_best_impl` with `require Future::IO::Impl::*`
  - Document that Future::IO 0.23+ has a built-in default impl that works without configuration

**Step 1: Update example and POD**
**Step 2: Commit**

```
git add examples/slow-redis/app.pl lib/Async/Redis.pm
git commit -m "docs: update event loop configuration for Future::IO 0.23+"
```

---

### Task 8: Full test suite verification

**Step 1: Run complete test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && REDIS_HOST=localhost prove -lr t/ 2>&1'`

Expected: All tests pass except the pre-existing unix-socket Docker-for-Mac issue.

**Step 2: Verify no IO::Async references remain in test code**

Run: `grep -r "IO::Async\|load_impl\|get_loop\|init_loop" t/ --include="*.pm" --include="*.t"`
Expected: No matches (or only comments)

**Step 3: Final commit if any fixups needed**
