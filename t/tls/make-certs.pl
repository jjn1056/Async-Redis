#!/usr/bin/env perl
# Write a self-signed certificate and key for the test TLS Redis
# (t/docker-compose.yml, service redis-tls) next to this script. The
# redis image has no openssl binary, so they are made here.
use strict;
use warnings;
use File::Basename qw(dirname);
use IO::Socket::SSL::Utils qw(CERT_create PEM_cert2file PEM_key2file);

my $dir = dirname(__FILE__);
my ($cert, $key) = CERT_create(
    CA      => 1,
    subject => { commonName => 'localhost' },
);
PEM_cert2file($cert, "$dir/cert.pem");
PEM_key2file($key, "$dir/key.pem");
chmod 0644, "$dir/cert.pem", "$dir/key.pem";    # readable by redis in the container
print "Wrote $dir/cert.pem and $dir/key.pem\n";
