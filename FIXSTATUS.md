# Fix: Concurrent Command Response Matching with Response Queue Pattern

## Status: In Progress

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

### Step 8: Code Review - PENDING

### Step 9: Documentation - PENDING

### Step 10: Final Verification - PENDING

## Test Results

### Baseline (before changes)
```
Files=65, Tests=347 - All passing
```

## Notes

- Branch: fix/response-queue-inflight-tracking
- Breaking changes: Acceptable per user preference
