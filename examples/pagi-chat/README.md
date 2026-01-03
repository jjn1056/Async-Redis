# Multi-Worker WebSocket Chat

This example demonstrates **Future::IO::Redis** working with **PAGI** in a multi-worker environment. Messages are broadcast across all workers using Redis PubSub.

## How It Works

```
                    ┌─────────────────┐
                    │     Redis       │
                    │   PubSub        │
                    │  (chat:lobby)   │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Worker 1 │        │ Worker 2 │        │ Worker 3 │
   │ (PID X)  │        │ (PID Y)  │        │ (PID Z)  │
   └────┬─────┘        └────┬─────┘        └────┬─────┘
        │                   │                   │
   ┌────┴────┐         ┌────┴────┐         ┌────┴────┐
   │ Clients │         │ Clients │         │ Clients │
   └─────────┘         └─────────┘         └─────────┘
```

Each worker:
1. Maintains its own Redis **subscriber** connection
2. Tracks its locally connected WebSocket clients
3. When a client sends a message, **publishes** to Redis
4. Receives published messages and broadcasts to local clients

## Running

```bash
# Start Redis
docker run -d -p 6379:6379 redis

# Run with multiple workers
REDIS_HOST=localhost pagi-server \
    --app examples/pagi-chat/app.pl \
    --port 5000 \
    --workers 4

# Open multiple browser tabs to:
#   http://localhost:5000/chat.html
#
# Or use websocat:
#   websocat ws://localhost:5000/
```

## Key Features Demonstrated

- **Fork-safe connections** - Each worker creates its own Redis connections after fork
- **PubSub** - Real-time cross-worker message broadcasting
- **Non-blocking I/O** - All operations use async/await
- **Event loop agnostic** - Uses `Future::IO->load_impl('IOAsync')`

## Requirements

- PAGI (0.001+)
- Future::IO::Redis
- Redis server
