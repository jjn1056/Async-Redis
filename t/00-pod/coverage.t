# t/00-pod/coverage.t
#
# Every public method is documented. Release testing only.
use strict;
use warnings;
use Test::More;

plan skip_all => 'Set RELEASE_TESTING to check POD coverage'
    unless $ENV{RELEASE_TESTING};
eval { require Test::Pod::Coverage; Test::Pod::Coverage->import; 1 }
    or plan skip_all => 'Test::Pod::Coverage required to check POD coverage';

# Redis command methods are documented together, under "Redis Commands"
# in Async::Redis: the generated wrappers in Async::Redis::Commands, and
# the few that Async::Redis defines itself.
my $redis_command = qr/^[a-z][a-z0-9_]*$/;
my %params = (
    'Async::Redis::Commands' => { trustme => [$redis_command] },
    'Async::Redis'           => {
        trustme => [qr/^(?:get|set|del|incr|lpush|rpush|lpop|lrange|flushdb)$/],
    },
);

# Internal: their POD says they are not a public API.
my %internal = map { $_ => 1 } qw(
    Async::Redis::Connection
    Async::Redis::AutoPipeline
    Async::Redis::KeyExtractor
    Async::Redis::Telemetry
);

for my $module (grep { !$internal{$_} } all_modules('lib')) {
    pod_coverage_ok($module, $params{$module} // {}, "$module is documented");
}

done_testing;
