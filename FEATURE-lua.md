# Feature: Enhanced Lua Script Helper API

## Status: PLANNING

## Overview

Enhance Async::Redis Lua scripting support with named command registration, automatic EVALSHA optimization, and pipeline integration. Primary use case: PAGI::Channels Redis backend.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| @var syntax | No | Explicit > magic |
| Key detection | Explicit count | Clear semantics |
| Method install | Both, opt-in | Flexible, not surprising |
| Pipeline | Day one | Core use case |
| Pool | Defer | Layered design |
| Constructor | Method first | Primitives before sugar |
| PAGI scripts | As tests | Real-world validation |
| Min Redis | 2.6 | Wide compatibility |

## Target API

```perl
# Define a command
$redis->define_command(publish_to_group => {
    keys => 1,
    lua  => <<'LUA',
        local members = redis.call('SMEMBERS', KEYS[1])
        for _, channel in ipairs(members) do
            redis.call('LPUSH', 'queue:' .. channel, ARGV[1])
        end
        return #members
LUA
    install => 1,  # Optional: install as method
});

# Call via run_script (always works)
my $count = await $redis->run_script('publish_to_group', 'topic:chat', $msg);

# Call as method (when install => 1)
my $count = await $redis->publish_to_group('topic:chat', $msg);

# Works in pipelines
my $pipe = $redis->pipeline;
$pipe->run_script('publish_to_group', 'topic:room1', $msg1);
$pipe->run_script('publish_to_group', 'topic:room2', $msg2);
my $results = await $pipe->execute;

# Preload scripts (useful before pipeline)
await $redis->preload_scripts;
```

---

## Implementation Plan

### Step 1: Enhance Async::Redis::Script Class

**Goal:** Upgrade Script.pm to support named registration and richer metadata.

#### Sub-steps:

1.1. **Run baseline tests**
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
REDIS_HOST=localhost prove -lr t/
```
Record: Files=??, Tests=??, Pass/Fail

1.2. **Add metadata fields to Script.pm**
- `name` - optional command name for registry
- `num_keys` - number of KEYS (integer or 'dynamic')
- `description` - optional documentation string
- `loaded_on` - track which connections have loaded this script

1.3. **Add `run()` method as preferred entry point**
```perl
async sub run {
    my ($self, $keys_aref, $args_aref) = @_;
    $keys_aref //= [];
    $args_aref //= [];
    my $numkeys = scalar @$keys_aref;
    return await $self->call_with_keys($numkeys, @$keys_aref, @$args_aref);
}
```

1.4. **Add `run_on()` method for explicit connection**
```perl
async sub run_on {
    my ($self, $redis, $keys_aref, $args_aref) = @_;
    # Run script on specific connection (for pipeline support)
}
```

1.5. **Update POD documentation**
- Document new methods
- Add examples for PAGI::Channels use case
- Document EVALSHA fallback behavior

1.6. **Run tests, verify no regressions**
```bash
REDIS_HOST=localhost prove -lr t/
```

#### Review checklist:
- [ ] No security issues (script injection, etc.)
- [ ] No dead/unused code
- [ ] No anti-patterns
- [ ] Clean architecture

#### Commit:
```bash
git add -A && git commit -m "Enhance Script.pm with metadata and run() method"
```

---

### Step 2: Add Script Registry to Async::Redis

**Goal:** Implement `define_command()` and `run_script()` methods.

#### Sub-steps:

2.1. **Run baseline tests**
```bash
REDIS_HOST=localhost prove -lr t/
```

2.2. **Add `_scripts` registry hash to constructor**
```perl
# In new()
_scripts => {},
```

2.3. **Implement `define_command()` method**
```perl
sub define_command {
    my ($self, $name, $def) = @_;

    die "Command name required" unless $name;
    die "Lua script required" unless $def->{lua};

    my $script = Async::Redis::Script->new(
        redis    => $self,
        name     => $name,
        script   => $def->{lua},
        num_keys => $def->{keys} // 'dynamic',
    );

    $self->{_scripts}{$name} = $script;

    # Optional method installation
    if ($def->{install}) {
        $self->_install_script_method($name);
    }

    return $script;
}
```

2.4. **Implement `run_script()` method**
```perl
async sub run_script {
    my ($self, $name, @args) = @_;

    my $script = $self->{_scripts}{$name}
        or die "Unknown script: $name";

    my $num_keys = $script->num_keys;
    if ($num_keys eq 'dynamic') {
        # First arg is key count
        $num_keys = shift @args;
    }

    my @keys = splice(@args, 0, $num_keys);
    return await $script->run(\@keys, \@args);
}
```

2.5. **Implement `_install_script_method()` helper**
```perl
sub _install_script_method {
    my ($self, $name) = @_;

    my $method = sub {
        my ($self, @args) = @_;
        return $self->run_script($name, @args);
    };

    no strict 'refs';
    *{"Async::Redis::$name"} = $method;
}
```

2.6. **Add `get_script()` and `list_scripts()` accessors**
```perl
sub get_script { shift->{_scripts}{shift()} }
sub list_scripts { keys %{shift->{_scripts}} }
```

2.7. **Run tests, verify no regressions**

#### Review checklist:
- [ ] No namespace pollution from installed methods
- [ ] Proper error handling for missing scripts
- [ ] No memory leaks in registry
- [ ] Thread/fork safety considered

#### Commit:
```bash
git commit -am "Add script registry with define_command() and run_script()"
```

---

### Step 3: Pipeline Integration

**Goal:** Make defined scripts work in pipelines with proper EVALSHA handling.

#### Sub-steps:

3.1. **Run baseline tests**
```bash
REDIS_HOST=localhost prove -lr t/
```

3.2. **Add `run_script()` to Pipeline.pm AUTOLOAD**
- Capture script name and args
- Queue as pending operation

3.3. **Implement `preload_scripts()` method on Async::Redis**
```perl
async sub preload_scripts {
    my ($self) = @_;

    for my $name ($self->list_scripts) {
        my $script = $self->get_script($name);
        await $self->script_load($script->script);
    }

    return scalar $self->list_scripts;
}
```

3.4. **Modify `_execute_pipeline()` to preload scripts**
- Before sending pipeline, check for script commands
- Ensure scripts are loaded via SCRIPT LOAD
- Use EVALSHA in pipeline (not EVAL)

3.5. **Handle NOSCRIPT in pipeline results**
- If any EVALSHA returns NOSCRIPT, retry that command with EVAL
- Or: preload guarantees this won't happen

3.6. **Run tests, verify no regressions**

#### Review checklist:
- [ ] Pipeline atomicity preserved
- [ ] No deadlock potential
- [ ] Error handling complete
- [ ] Performance acceptable (no unnecessary round-trips)

#### Commit:
```bash
git commit -am "Integrate defined scripts with pipeline execution"
```

---

### Step 4: Comprehensive Test Suite

**Goal:** Add thorough tests including PAGI::Channels use cases.

#### Sub-steps:

4.1. **Run baseline tests**
```bash
REDIS_HOST=localhost prove -lr t/
```

4.2. **Create `t/60-scripting/define-command.t`**
- Test basic define_command
- Test run_script
- Test installed methods
- Test dynamic key count
- Test error cases (missing script, bad args)

4.3. **Create `t/60-scripting/script-registry.t`**
- Test list_scripts
- Test get_script
- Test multiple scripts
- Test script replacement/redefinition

4.4. **Create `t/60-scripting/pipeline-scripts.t`**
- Test run_script in pipeline
- Test preload_scripts
- Test mixed regular commands and scripts
- Test NOSCRIPT recovery

4.5. **Create `t/60-scripting/pagi-channels.t`**
- Implement channel_publish script
- Implement channel_poll script
- Implement channel_cleanup script
- Test realistic PAGI::Channels workflow

4.6. **Run full test suite**
```bash
REDIS_HOST=localhost prove -lr t/
```

#### Review checklist:
- [ ] Edge cases covered
- [ ] Error paths tested
- [ ] No test pollution between subtests
- [ ] Tests are deterministic

#### Commit:
```bash
git commit -am "Add comprehensive Lua scripting test suite"
```

---

### Step 5: Documentation and Polish

**Goal:** Complete POD documentation and cleanup.

#### Sub-steps:

5.1. **Run baseline tests**
```bash
REDIS_HOST=localhost prove -lr t/
```

5.2. **Update Async::Redis.pm POD**
- Add SCRIPTING section
- Document define_command() with examples
- Document run_script() with examples
- Document preload_scripts()
- Add PAGI::Channels example

5.3. **Update Async::Redis::Script.pm POD**
- Document all public methods
- Add usage examples
- Document EVALSHA optimization

5.4. **Update Async::Redis::Pipeline.pm POD**
- Document script support in pipelines

5.5. **Update CLAUDE.md**
- Add Lua scripting architecture notes
- Document script registry pattern

5.6. **Final code review**
- Remove any TODO comments
- Remove any debug code
- Ensure consistent code style
- Check for any remaining issues

5.7. **Run full test suite**
```bash
REDIS_HOST=localhost prove -lr t/
```

#### Review checklist:
- [ ] All public methods documented
- [ ] Examples are correct and runnable
- [ ] No typos or unclear language
- [ ] Consistent terminology

#### Commit:
```bash
git commit -am "Complete documentation for Lua scripting features"
```

---

### Step 6: Final Verification and Merge Prep

**Goal:** Ensure everything works and prepare for merge.

#### Sub-steps:

6.1. **Run full test suite**
```bash
REDIS_HOST=localhost prove -lr t/
```

6.2. **Run PAGI::Channels integration scenario**
- Manual test of realistic workflow
- Verify performance is acceptable

6.3. **Update Changes file**
- Document new features
- Note any API changes

6.4. **Review entire diff from main**
```bash
git diff main...HEAD
```

6.5. **Squash/rebase if needed for clean history**

6.6. **Update FEATURE-lua.md with completion status**

#### Final commit:
```bash
git commit -am "Complete Lua script helpers feature - ready for merge"
```

---

## Test Commands Reference

```bash
# Setup
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
cd t && docker compose up -d && cd ..

# Run all tests
REDIS_HOST=localhost prove -lr t/

# Run scripting tests only
REDIS_HOST=localhost prove -lr t/60-scripting/

# Verbose single test
REDIS_HOST=localhost prove -lv t/60-scripting/define-command.t

# Cleanup
cd t && docker compose down
```

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/Async/Redis.pm` | Modify | Add define_command, run_script, preload_scripts |
| `lib/Async/Redis/Script.pm` | Modify | Add metadata, run(), run_on() |
| `lib/Async/Redis/Pipeline.pm` | Modify | Add run_script support |
| `t/60-scripting/define-command.t` | Create | Test command definition |
| `t/60-scripting/script-registry.t` | Create | Test registry operations |
| `t/60-scripting/pipeline-scripts.t` | Create | Test pipeline integration |
| `t/60-scripting/pagi-channels.t` | Create | PAGI::Channels use cases |
| `Changes` | Modify | Document new features |
| `CLAUDE.md` | Modify | Architecture notes |

---

## Rollback Plan

Each step has its own commit. If issues discovered:

```bash
# Revert last commit
git revert HEAD

# Or reset to specific step
git log --oneline  # Find commit
git reset --hard <commit-sha>

# Or abandon entirely
git checkout main
git branch -D feature/lua-script-helpers
```

---

## Progress Tracking

| Step | Status | Tests Before | Tests After | Commit |
|------|--------|--------------|-------------|--------|
| 1. Enhance Script.pm | COMPLETE | 66/352 pass | 66/352 pass | 70afaf8 |
| 2. Script Registry | COMPLETE | 66/352 pass | 66/352 pass | 806ac1f |
| 3. Pipeline Integration | COMPLETE | 66/352 pass | 66/352 pass | 95c9577 |
| 4. Test Suite | COMPLETE | 66/352 pass | 70/373 pass | 4c6ed16 |
| 5. Documentation | COMPLETE | 70/373 pass | 70/373 pass | (pending) |
| 6. Final Verification | IN PROGRESS | | | |

---

## Scratch Space

(Use this area for notes, debugging info, context preservation)

