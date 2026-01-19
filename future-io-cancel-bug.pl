#!/usr/bin/env perl
# future-io-cancel-bug.pl
#
# Demonstrates a bug in Future::IO::Impl::IOAsync where cancelling a future
# that's waiting on a socket read doesn't properly clean up internal state.
#
# This is SELF-CONTAINED - no Redis or external server required.
#
# Run with different backends:
#   perl future-io-cancel-bug.pl              # defaults to IOAsync
#   perl future-io-cancel-bug.pl IOAsync
#   perl future-io-cancel-bug.pl UV
#
use strict;
use warnings;
use 5.018;

use IO::Socket::INET;
use Future::IO;

my $backend = shift @ARGV // 'IOAsync';

print "=" x 60, "\n";
print "Future::IO Cancellation Test\n";
print "=" x 60, "\n\n";

# Load the requested backend
print "Loading backend: $backend\n";
eval {
    Future::IO->load_impl($backend);
    1;
} or die "Cannot load Future::IO backend '$backend': $@\n";

print "\nVersions:\n";
print "  Future::IO: $Future::IO::VERSION\n";
if ($backend eq 'IOAsync') {
    require IO::Async::Loop;
    print "  Future::IO::Impl::IOAsync: $Future::IO::Impl::IOAsync::VERSION\n";
    print "  IO::Async::Loop: $IO::Async::Loop::VERSION\n";
} elsif ($backend eq 'UV') {
    print "  Future::IO::Impl::UV: $Future::IO::Impl::UV::VERSION\n";
    print "  UV: $UV::VERSION\n";
}
print "\n";

# Create a listening socket (acts as a server that never sends data)
print "1. Creating listening socket...\n";
my $server = IO::Socket::INET->new(
    LocalHost => '127.0.0.1',
    LocalPort => 0,  # Let OS pick a port
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
) or die "Cannot create server socket: $!";

my $port = $server->sockport;
print "   Listening on 127.0.0.1:$port\n\n";

# Connect a client socket
print "2. Connecting client socket...\n";
my $client = IO::Socket::INET->new(
    PeerHost => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die "Cannot connect: $!";
print "   Connected.\n\n";

# Accept on server side (so the connection is established)
my $accepted = $server->accept;
print "3. Server accepted connection.\n\n";

# Start a read operation on the client - server will never send anything
print "4. Creating Future::IO->read() on client socket...\n";
print "   (Server will never send data, so this would block forever)\n";
my $read_future = Future::IO->read($client, 1024);
print "   Future state: pending\n\n";

# Cancel the read future
print "5. Cancelling the read future with ->cancel()...\n";
$read_future->cancel;
print "   Future state: cancelled=" . ($read_future->is_cancelled ? "yes" : "no") . "\n\n";

# Close the client socket
print "6. Closing client socket...\n";
shutdown($client, 2);
close($client);
print "   Socket closed.\n\n";

# Clean up server
close($accepted);
close($server);

# Run event loop to trigger any deferred callbacks
print "7. Running event loop to flush callbacks...\n";
eval {
    Future::IO->sleep(0.1)->get;
};
if ($@) {
    print "   ERROR: $@\n";
} else {
    print "   Event loop completed cleanly.\n";
}

print "\n", "=" x 60, "\n";
print "RESULTS ($backend backend):\n";
print "=" x 60, "\n";
print "If you see warnings about 'uninitialized value' or errors about\n";
print "'Can't call method on undefined value', the bug is present.\n\n";
print "Expected: No warnings, clean cancellation, clean socket close.\n";
