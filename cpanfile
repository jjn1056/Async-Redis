# Runtime dependencies
requires 'perl', '5.018';
requires 'Future', '0.49';
requires 'Future::AsyncAwait', '0.66';
requires 'Future::IO', '0.17';
requires 'IO::Socket::INET';
requires 'Socket';
requires 'Time::HiRes';
requires 'Digest::SHA';

# Test dependencies
on 'test' => sub {
    requires 'Test2::V0';
    requires 'Test::Lib';
    requires 'IO::Async::Loop';
    requires 'IO::Async::Timer::Periodic';
    requires 'IO::Async::Process';
    requires 'Future::IO::Impl::IOAsync';
};

# Development dependencies
on 'develop' => sub {
    requires 'Dist::Zilla';
};
