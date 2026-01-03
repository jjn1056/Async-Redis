#!/usr/bin/env perl
#
# Multi-Worker WebSocket Chat using PAGI + Future::IO::Redis
#
# This example demonstrates Future::IO::Redis PubSub for real-time
# messaging across multiple worker processes. Each worker maintains
# its own Redis subscription and broadcasts to its connected clients.
#
# Run with multiple workers:
#   pagi-server --app examples/pagi-chat/app.pl --port 5000 --workers 4
#
# Test with multiple browser tabs or:
#   websocat ws://localhost:5000/
#
# Messages sent by any client are broadcast to ALL clients across
# ALL workers via Redis PubSub.
#
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use PAGI::WebSocket;

# Use IO::Async as our event loop (PAGI uses this)
use IO::Async::Loop;
Future::IO->load_impl('IOAsync');

use lib 'lib';
use Future::IO::Redis;

my $CHANNEL = 'chat:lobby';

# Track connected clients for this worker
my @clients;

# Redis subscriber (one per worker, set up on first connection)
my $subscriber;
my $subscriber_ready;

# Set up the Redis subscriber for this worker
async sub ensure_subscriber {
    return if $subscriber_ready;

    my $redis = Future::IO::Redis->new(
        host => $ENV{REDIS_HOST} // 'localhost',
        port => $ENV{REDIS_PORT} // 6379,
    );
    await $redis->connect;

    $subscriber = await $redis->subscribe($CHANNEL);
    $subscriber_ready = 1;

    # Background task: receive messages and broadcast to local clients
    (async sub {
        while (my $msg = await $subscriber->next_message) {
            next unless $msg->{type} eq 'message';

            # Broadcast to all clients connected to THIS worker
            for my $ws (@clients) {
                eval { await $ws->send_text($msg->{data}) };
            }
        }
    })->();

    print "Worker $$ subscribed to $CHANNEL\n";
}

# Publish a message (uses separate connection for pub)
async sub publish_message {
    my ($text) = @_;

    # Create a fresh connection for publishing
    # (subscriber connection is in pubsub mode)
    my $redis = Future::IO::Redis->new(
        host => $ENV{REDIS_HOST} // 'localhost',
        port => $ENV{REDIS_PORT} // 6379,
    );
    await $redis->connect;
    await $redis->publish($CHANNEL, $text);
    $redis->disconnect;
}

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    die "Expected websocket" if $scope->{type} ne 'websocket';

    # Ensure subscriber is running for this worker
    await ensure_subscriber();

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    await $ws->accept;

    # Track this client
    push @clients, $ws;
    my $client_id = "user-" . substr(rand(), 2, 6);
    print "Worker $$: $client_id connected (" . scalar(@clients) . " local clients)\n";

    # Announce join
    await publish_message("*** $client_id joined the chat ***");

    $ws->on_close(sub {
        my ($code) = @_;
        @clients = grep { $_ != $ws } @clients;
        print "Worker $$: $client_id disconnected (" . scalar(@clients) . " local clients)\n";
        # Note: Can't await in callback, fire-and-forget
        publish_message("*** $client_id left the chat ***");
    });

    # Handle incoming messages
    await $ws->each_text(async sub {
        my ($text) = @_;
        await publish_message("[$client_id] $text");
    });
};

$app;
