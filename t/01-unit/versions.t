# t/01-unit/versions.t
#
# Every module in the distribution carries the distribution's version.
# A module without one reads as undef, which CPAN.pm takes for a
# downgrade of an installed release that had one (GitHub #14). The
# versions are stamped at build time, so the per-module check runs in a
# built dist (dzil test); a checkout checks the main version only.
use strict;
use warnings;
use Test2::V0;
use File::Find ();
use JSON::PP ();
use lib 'lib';
use Async::Redis;

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file: $!";
    local $/;
    return scalar <$fh>;
}

if (-e 'dist.ini') {
    my ($version) = slurp('dist.ini') =~ /^version\s*=\s*(\S+)/m;
    is(Async::Redis->VERSION, $version, 'Async::Redis has the version in dist.ini');
}

if (-e 'META.json') {
    my $version = JSON::PP::decode_json(slurp('META.json'))->{version};
    is(Async::Redis->VERSION, $version, 'Async::Redis has the version in META.json');

    my @modules;
    File::Find::find(sub { push @modules, $File::Find::name if /\.pm\z/ }, 'lib');
    for my $file (sort @modules) {
        for my $package (slurp($file) =~ /^package\s+([\w:]+)\s*;/mg) {
            require $file =~ s{^lib/}{}r;
            is($package->VERSION, $version, "$package has the dist version");
        }
    }
}
else {
    note 'The per-module check runs in the built dist (dzil test)';
}

done_testing;
