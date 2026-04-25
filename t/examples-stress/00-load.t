use strict;
use warnings;
use Test2::V0;
use lib 'examples/stress/lib';

# Test2::V0 does not export require_ok; use the lives idiom instead.
ok lives { require Stress::Metrics   }, 'load Stress::Metrics';
ok lives { require Stress::Integrity }, 'load Stress::Integrity';
ok lives { require Stress::Output    }, 'load Stress::Output';
ok lives { require Stress::Chaos     }, 'load Stress::Chaos';
ok lives { require Stress::Workload  }, 'load Stress::Workload';
ok lives { require Stress::Harness   }, 'load Stress::Harness';

done_testing;
