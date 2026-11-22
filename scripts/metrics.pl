#!/usr/bin/perl
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Metrics endpoint for Prometheus: GET /metrics answers with the file the
# metrics.amxx plugin keeps up to date (see plugins/amxmodx/scripting/metrics.sma)
# plus hlds_up, which is 0 when that file is missing or stale: the server is
# down, hung or still loading. entrypoint.sh starts this when METRICS_PORT is
# set. One request at a time, perl-base only.
#
#   metrics.pl <port> [bind address] [file]
use strict;
use warnings;
use IO::Socket::INET;

my $port = shift // 9137;
my $bind = shift // '0.0.0.0';
my $file = shift // '/hlds/.runtime/metrics.prom';
my $stale = 30;    # seconds; the plugin writes every 5

my $server = IO::Socket::INET->new(
    LocalAddr => $bind,
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 8,
    ReuseAddr => 1,
) or die "[metrics] cannot listen on $bind:$port: $!\n";
print "[metrics] serving http://$bind:$port/metrics\n";
$| = 1;
$SIG{PIPE} = 'IGNORE';

sub metrics {
    my $body = '';
    my $up   = 0;
    my @stat = stat $file;
    if (@stat && time - $stat[9] <= $stale && open my $fh, '<', $file) {
        local $/;
        $body = <$fh> // '';
        close $fh;
        $up = 1 if $body =~ /^hlds_updated_timestamp_seconds /m;
    }
    $body = '' unless $up;
    return $body
        . "# HELP hlds_up 1 while the game server is running and reporting.\n"
        . "# TYPE hlds_up gauge\nhlds_up $up\n";
}

while (1) {
    my $client = $server->accept or next;
    # A client that connects and sends nothing must not hold the endpoint.
    my $request = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        my $line = <$client>;
        alarm 0;
        $line;
    };
    alarm 0;
    my ($status, $type, $body) = ('404 Not Found', 'text/plain', "not found\n");
    if (defined $request && $request =~ m{^(GET|HEAD) /metrics(?:\?\S*)? HTTP/}) {
        ($status, $type, $body) = ('200 OK', 'text/plain; version=0.0.4; charset=utf-8', metrics());
        $body = '' if $1 eq 'HEAD';
    }
    elsif (!defined $request) {
        close $client;
        next;
    }
    print {$client} "HTTP/1.0 $status\r\nContent-Type: $type\r\nContent-Length: "
        . length($body) . "\r\nConnection: close\r\n\r\n$body";
    close $client;
}
