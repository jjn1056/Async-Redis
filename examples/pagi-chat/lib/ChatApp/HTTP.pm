package ChatApp::HTTP;

use strict;
use warnings;
use Future::AsyncAwait;
use JSON::MaybeXS;
use File::Spec;
use File::Basename qw(dirname);

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my $JSON = JSON::MaybeXS->new->utf8->canonical;
my $PUBLIC_DIR = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');

my %MIME_TYPES = (
    html => 'text/html; charset=utf-8',
    css  => 'text/css; charset=utf-8',
    js   => 'application/javascript; charset=utf-8',
    json => 'application/json; charset=utf-8',
    png  => 'image/png',
    ico  => 'image/x-icon',
);

sub handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';
        my $method = $scope->{method} // 'GET';

        if ($path =~ m{^/api/}) {
            return await _handle_api($scope, $receive, $send, $path, $method);
        }

        return await _serve_static($scope, $receive, $send, $path);
    };
}

async sub _handle_api {
    my ($scope, $receive, $send, $path, $method) = @_;

    my ($status, $data);

    if ($path eq '/api/rooms' && $method eq 'GET') {
        my $rooms = await get_all_rooms();
        $data = [
            map {
                { name => $_, users => scalar(keys %{$rooms->{$_}{users}}) }
            }
            sort keys %$rooms
        ];
        $status = 200;
    }
    elsif ($path =~ m{^/api/room/([^/]+)/history$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = await get_room($room_name);
        if ($room) {
            $data = await get_room_messages($room_name, 100);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path =~ m{^/api/room/([^/]+)/users$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = await get_room($room_name);
        if ($room) {
            $data = await get_room_users($room_name);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path eq '/api/stats' && $method eq 'GET') {
        $data = await get_stats();
        $status = 200;
    }
    else {
        $data = { error => 'Not found' };
        $status = 404;
    }

    my $body = $JSON->encode($data);

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
            ['content-length', length($body)],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => $body,
    });
}

async sub _serve_static {
    my ($scope, $receive, $send, $path) = @_;

    $path = '/index.html' if $path eq '/';
    $path =~ s/\.\.//g;
    $path =~ s|//+|/|g;

    my $file_path = File::Spec->catfile($PUBLIC_DIR, $path);

    unless (-f $file_path && -r $file_path) {
        return await _send_404($send);
    }

    my ($ext) = $file_path =~ /\.(\w+)$/;
    my $content_type = $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';

    my $content;
    {
        open my $fh, '<:raw', $file_path or return await _send_500($send);
        local $/;
        $content = <$fh>;
        close $fh;
    }

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type', $content_type],
            ['content-length', length($content)],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => $content,
    });
}

async sub _send_404 {
    my ($send) = @_;
    my $body = '{"error":"Not found"}';
    await $send->({
        type    => 'http.response.start',
        status  => 404,
        headers => [['content-type', 'application/json']],
    });
    await $send->({ type => 'http.response.body', body => $body });
}

async sub _send_500 {
    my ($send) = @_;
    my $body = '{"error":"Internal server error"}';
    await $send->({
        type    => 'http.response.start',
        status  => 500,
        headers => [['content-type', 'application/json']],
    });
    await $send->({ type => 'http.response.body', body => $body });
}

1;
