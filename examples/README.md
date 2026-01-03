# Future::IO::Redis Examples

This directory contains example applications demonstrating Future::IO::Redis.

## Prerequisites

All examples require a Redis server. Use the included docker-compose configuration:

```bash
# Start Redis
docker compose -f examples/docker-compose.yml up -d

# Verify Redis is running
docker compose -f examples/docker-compose.yml ps

# Stop Redis
docker compose -f examples/docker-compose.yml down

# Stop Redis and remove data volume
docker compose -f examples/docker-compose.yml down -v
```

## Examples

### pagi-chat

A multi-worker chat application demonstrating Redis PubSub for real-time
cross-worker message broadcasting. Port of PAGI's websocket-chat-v2 example.

```bash
# Start the chat server
REDIS_HOST=localhost pagi-server \
    --app examples/pagi-chat/app.pl \
    --port 5000 \
    --workers 4

# Open http://localhost:5000
```

See [pagi-chat/README.md](pagi-chat/README.md) for details.

## Environment Variables

- `REDIS_HOST` - Redis server hostname (default: localhost)
- `REDIS_PORT` - Redis server port (default: 6379)
