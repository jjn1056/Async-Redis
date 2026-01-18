# Fix: Concurrent Command Response Matching with Response Queue Pattern

## Status: COMPLETE

## Problem

When multiple async commands fire concurrently on a single connection, responses can get mismatched. Multiple coroutines race to read from the shared parser, and the order they read may not match the order they sent.

## Solution

Implement Response Queue pattern with proper inflight tracking:
1. Commands register in inflight queue BEFORE sending
2. Single reader coroutine processes responses in FIFO order
3. Proper synchronization prevents multiple readers

## Progress

### Step 1: Create Failing Test - COMPLETE
- [x] Baseline tests pass (65 tests, all successful)
- [x] Create t/92-concurrency/response-ordering.t
- [x] Verify test demonstrates the bug

Bug demonstrated:
- concurrent GET commands: GET 3 got value:4, GET 4 got value:5, etc.
- mixed command types: INCR expected 2 got 1, LPUSH expected 1 got 3
- inflight tracking: Connection desynced, caused timeout

### Step 2: Implement Inflight Queue Data Structure - COMPLETE
- [x] Add _reading_responses and _response_reader flags
- [x] Add _add_inflight() helper method
- [x] Add _shift_inflight() helper method
- [x] Reset flags in connect/disconnect/_reset_connection/_check_fork

### Step 3: Implement Single Reader Loop - COMPLETE
- [x] Add _fail_all_inflight() for error handling
- [x] Add _ensure_response_reader() with FIFO processing

### Step 4: Modify command() to Use Response Queue - COMPLETE
- [x] Create response Future before sending
- [x] Register in inflight queue before sending
- [x] Trigger reader after send
- [x] Await response Future instead of reading directly
- [x] All 66 tests pass (352 test cases)

### Step 5: Update Pipeline Integration - COMPLETE
- [x] Add _wait_for_inflight_drain() helper
- [x] Wait for inflight before pipeline
- [x] Set/reset _reading_responses flag
- [x] All pipeline tests pass

### Step 6: Update PubSub and Transaction Integration - COMPLETE
- [x] Add inflight drain to subscribe/psubscribe/ssubscribe
- [x] Clean transition to PubSub mode
- [x] All PubSub and transaction tests pass

### Step 7: Fix Original Failing Test - COMPLETE
- [x] t/91-reliability/queue-overflow.t passes
- [x] inflight tracking works correctly

### Step 8: Code Review - COMPLETE
- [x] Security review - no passwords in error messages
- [x] Removed unused _response_reader field (dead code)
- [x] Verified synchronization invariants

### Step 9: Documentation - COMPLETE
- [x] Added CONCURRENT COMMANDS section to POD
- [x] Added "Safe concurrent commands" feature
- [x] Updated CLAUDE.md with Response Queue pattern

### Step 10: Final Verification - COMPLETE
- [x] All 66 tests pass (352 test cases)
- [x] Response ordering test passes
- [x] Original queue-overflow test passes

## Test Results

### Baseline (before changes)
```
Files=65, Tests=347 - All passing
```

### Final (after changes)
```
Files=66, Tests=352 - All passing
```

## Commits

1. ffca0cf - Add failing test demonstrating bug
2. b7957e7 - Add inflight queue data structure
3. df00b44 - Implement single reader loop
4. 3454f4a - Wire command() to use response queue (core fix)
5. 710ceb1 - Update pipeline integration
6. 0693d0c - Integrate PubSub and transactions
7. e7d8a87 - Update FIXSTATUS.md
8. a1d77ef - Code review: remove dead code
9. 6ca5cba - Update documentation

## Notes

- Branch: fix/response-queue-inflight-tracking
- Breaking changes: None (internal implementation change only)
- The fix is transparent to users - existing code works unchanged
