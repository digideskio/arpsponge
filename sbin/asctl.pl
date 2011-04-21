#!@PERL@ -I../lib
# ============================================================================
# @(#)$Id$
# ============================================================================
#
#         File:  asctl.pl
#
#        Usage:  see POD at end
#
#  Description:  ArpSponge ConTroL utility.
#
#       Author:  Steven Bakker (SB), <steven.bakker@ams-ix.net>
#      Created:  2011-03-24 15:38:13 CET
#
#   Copyright (c) 2011 AMS-IX B.V.; All rights reserved.
#
#   This module is free software; you can redistribute it and/or
#   modify it under the same terms as Perl itself. See perldoc perlartistic.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# ============================================================================

$0 =~ s|.*/||g;

use feature ':5.10';
use strict;
use warnings;
use Getopt::Long qw( GetOptions GetOptionsFromArray );
use POSIX qw( strftime floor );
use Pod::Usage;
use M6::ARP::Control::Client;
use Time::HiRes qw( time sleep );
use M6::ARP::Util qw( :all );
use M6::ReadLine qw( :all );
use NetAddr::IP;
use Term::ReadLine;

my $SPONGE_VAR    = '@SPONGE_VAR@';
my $CONN          = undef;
my $STATUS        = {};

# Values set on the Command Line.
my $opt_verbose   = 0;
my $opt_debug     = 0;
my $opt_test      = 0;
my $rundir        = $SPONGE_VAR;
my $MAX_HISTORY   = 1000;
my $HISTFILE      = "$::ENV{HOME}/.$0_history";

my ($REVISION) = '$Revision$' =~ /Revision: (\S+) \$/;
my $VERSION    = '@RELEASE@'."($REVISION)";
my $app_header = "\nThis is $0, v$VERSION\n\n"
               . "See \"perldoc $0\" for more information.\n"
               ;

END {
    $CONN && $CONN->close;
}

sub verbose(@) { print @_ if $opt_verbose; }
sub DEBUG(@)   { print_error(@_) if $opt_debug; }

my %Syntax = (
    'quit' => {},
    'ping $count $delay' => {
      '$count' => { type=>'int',   min=>1,    default=>1 },
      '$delay' => { type=>'float', min=>0.01, default=>1 },
    },
    'clear ip $ip'   => { '$ip' => { type=>'ip-range'  } },
    'clear arp $ip'  => { '$ip' => { type=>'ip-range'  } },
    'show ip $ip?'   => { '$ip' => { type=>'ip-filter' } },
    'show arp $ip?'  => { '$ip' => { type=>'ip-range'  } },
    'show status|version|uptime' => {},
    'show log $nlines?' => {
        '$nlines' => { type=>'int', min=>1 },
    },
    'sponge|unsponge $ip' => { '$ip' => { type=>'ip-range' } },
    'inform $dst_ip about $src_ip' => {
        '$dst_ip' => { type=>'ip-address' },
        '$src_ip' => { type=>'ip-address' }
    },
    'set ip $ip dead'   => { '$ip' => { type=>'ip-range'  } },
    'set ip $ip pending $pending?' => {
        '$ip'      => { type=>'ip-range'  },
        '$pending' => { type=>'int', min=>0 },
    },
    'set ip $ip mac $mac' => {
        '$ip'      => { type=>'ip-range'    },
        '$mac'     => { type=>'mac-address' },
    },
    'set ip $ip alive $mac?' => {
        '$ip'      => { type=>'ip-range'    },
        '$mac'     => { type=>'mac-address' },
    },
    'set max-pending|queuedepth $num' => {
        '$num'      => { type=>'int', min=>1 },
    },
    'set max-rate|flood-protection|proberate $rate' => {
        '$rate'      => { type=>'float', min=>0.001 },
    },
    'set learning $secs' => {
        '$secs'      => { type=>'int', min=>0 },
    },
    'set dummy $bool' => {
        '$bool'      => { type=>'bool' },
    },
    'set sweep (age|period) $secs' => {
        '$secs'      => { type=>'int', min=>1 },
    },
);

sub Main {
    my ($sockname, $args) = initialise();

    compile_syntax(\%Syntax) or die("** cannot continue\n");

    verbose "connecting to arpsponge on $sockname\n";
    if (!$opt_test) {
        $CONN = M6::ARP::Control::Client->create_client($sockname)
                    or die M6::ARP::Control::Client->error."\n";
    }
    ($STATUS) = get_status($CONN, {raw=>0, format=>1});
    verbose "$$STATUS{id}, v$$STATUS{version} (pid #$$STATUS{pid})\n";
    my $err = 0;

    if (@$args) {
        my $command = do_command($CONN, join(' ', @$args));
    }
    else {
        $M6::ReadLine::IP_NETWORK =
            NetAddr::IP->new("$$STATUS{network}/$$STATUS{prefixlen}");

        init_readline(interactive => $INTERACTIVE);
        while ( defined (my $input = $TERM->readline($PROMPT)) ) {
            next if $input =~ /^\s*(?:#.*)?$/;
            my $command = do_command($input, $CONN);

            if (!$CONN) {
                if ($command eq 'quit') {
                    verbose "connection closed\n";
                    last;
                }
            }
            elsif (!defined $CONN->send_command("ping")) {
                if ($command eq 'quit') {
                    verbose "connection closed\n";
                }
                else {
                    $err++;
                    print STDERR "** connection closed unexpectedly\n";
                }
                last;
            }
        }
    }
    $CONN && $CONN->close;
    exit $err;
}

sub do_command {
    my ($line, $conn) = @_;
    my %args = (-conn => $conn);
    my @parsed = ();

    if (parse_line($line, \@parsed, \%args)) {
        my $func_name = "do @parsed";
        $func_name =~ s/[\s-]+/_/g;
        my $func; eval '$func = \&'.$func_name;
        if (!defined $func) {
            return print_error(qq{@parsed: NOT IMPLEMENTED});
        }
        else {
            $func->($conn, \@parsed, \%args);
            return "@parsed";
        }
    }
    return "@parsed";
}

sub expand_ip_range {
    my ($arg_str, $name, $silent) = @_;

    $arg_str =~ s/\s*(?:-|\.\.|to)\s*/-/g;
    $arg_str =~ s/\s*,\s*/ /g;

    my @args = split(' ', $arg_str);

    DEBUG "range: <$arg_str>:", map {" <$_>"} @args;

    my @list;
    for my $ip_s (@args) {
        my ($lo_s, $hi_s) = split(/-/, $ip_s, 2);

        check_ip_address_arg({name=>$name}, $lo_s, $silent) or return;
        my $lo = ip2int($lo_s);
        DEBUG "lo: <$lo_s> $lo";
        my $hi;
        if ($hi_s) {
            check_ip_address_arg({name=>$name}, $hi_s, $silent) or return;
            $hi = ip2int($hi_s);
            DEBUG "hi: <$hi_s> $hi";
        }
        else { $hi = $lo; }

        if ($hi < $lo) {
            $silent or print_error(
                        qq{$name: "$lo_s-$hi_s" is not a valid IP range});
            return;
        }
        push @list, [ $lo, $hi, $lo_s, $hi_s ];
    }
    return \@list;
}

sub check_ip_range_arg {
    my ($spec, $arg, $silent) = @_;
    return expand_ip_range($arg, $spec->{name}) ? $arg : undef;
}

sub complete_ip_range {
    my $partial = shift @_;
    my @words   = split(/,/, $partial);
    if ($partial =~ /,$/) {
        $partial = '';
    }
    else {
        $partial = @words ? pop @words : '';
    }
    my $prefix  = join('', map { "$_," } @words);
    if ($partial =~ /^(.+-)(.*)$/) {
        $prefix .= $1;
        $partial = $2;
    }
    #print_error("\npartial: <$partial>; prefix: <$prefix>");
    return map { "$prefix$_" } complete_ip_address_arg($partial);
}

sub check_ip_filter_arg {
    my ($spec, $arg, $silent) = @_;
    if ($arg =~ /^all|alive|dead|pending|none$/i) {
        return $arg;
    }
    return check_ip_range_arg(@_);
}

sub complete_ip_filter {
    my $partial = shift;
    return (qw( all alive dead pending none ), complete_ip_range($partial));
}

sub check_send_command {
    my $conn = shift;
    my $command = join(' ', @_);

    return if !$conn;

    my $reply = $conn->send_command($command) or return;
       $reply =~ s/^\[(\S+)\]\s*\Z//m;

    if ($1 eq 'OK') {
        return $reply;
    }
    else {
        return print_error($reply);
    }
}

sub expand_ip_run {
    my $arg_str = shift;
    my $code = shift;

    my @args = split(' ', $arg_str);

    my @reply;
    my $list = expand_ip_range($arg_str, 'ip') or return;

    for my $elt (@$list) {
        my ($lo, $hi, $lo_s, $hi_s) = @$elt;
        for (my $ip = $lo; $ip <= $hi; $ip++) {
            my $sub = $code->(ip2hex(int2ip($ip)));
            return if !defined $sub;
            push @reply, $sub if length($sub);
        }
    }
    return join("\n", @reply);
}

sub do_quit {
    my ($conn, $parsed, $args) = @_;
    GetOptionsFromArray($$args{-options}) or return;
    my $reply = check_send_command($conn, 'quit') or return;
    print_output($reply);
}

sub do_ping {
    my ($conn, $parsed, $args) = @_;

    GetOptionsFromArray($$args{-options}) or return;

    my $count = $args->{'count'};
    my $delay = $args->{'delay'};

    my @rtt;
    my ($min_rtt, $max_rtt, $tot_rtt) = (undef,undef,0);
    my $interrupt = 0;
    local ($::SIG{INT}) = sub { $interrupt++ };
    my ($ns, $nr) = (0,0);
    my $global_start = time;
    for (my $n=0; $n<$count; $n++) {
        my $start = time;
        $ns++;
        if (my $reply = check_send_command($conn, 'ping')) {
            my $rtt   = (time - $start)*1000;
            $tot_rtt += $rtt;
            if (!defined $min_rtt) {
                $min_rtt = $max_rtt = $rtt;
            }
            else {
                $min_rtt = $rtt if $rtt < $min_rtt;
                $max_rtt = $rtt if $rtt > $max_rtt;
            }
            push @rtt, $rtt;
            $nr++;
            print_output(
                sprintf("%d bytes from #%d: time=%0.3f ms\n",
                        length($reply), $$STATUS{pid}, $rtt
                    )
            );
        }
        else {
            last;
        }
        sleep($delay) if $n < $count - 1;
        if ($interrupt) {
            print_error("** Interrupt");
            last;
        }
    }
    if ($count>1) {
        my $loss = ($ns - $nr) / ($ns ? $ns : 1) * 100;
           $loss = floor($loss+0.5);
        my $time = (time - $global_start)*1000;
           $time = floor($time+0.5);
        my $avg_rtt = $tot_rtt / ($nr ? $nr : 1);
        my $mdev_rtt = 0;
        for my $x (@rtt) { $mdev_rtt += abs($avg_rtt - $x) }
        $mdev_rtt = $mdev_rtt / ($nr ? $nr : 1);
        print_output("--- $$STATUS{id} ping statistics ---\n",
            sprintf("%d packets transmitted, %d received, ", $ns, $nr),
            sprintf("%d%% packet loss, time %dms\n", $loss, $time),
            sprintf("rtt min/avg/max/mdev = %0.3f/%0.3f/%0.3f/%0.3f ms\n",
                    $min_rtt, $avg_rtt, $max_rtt, $mdev_rtt)
        );
    }
}

sub do_inform_about {
    my ($conn, $parsed, $args) = @_;

    GetOptionsFromArray($args->{-options}) or return;
    my ($src, $dst) = (ip2hex($$args{'src_ip'}), ip2hex($$args{'dst_ip'}));
    my $reply = check_send_command($conn, 'inform', $dst, $src) or return;
    my ($opts, $output, $tag) = parse_server_reply($reply, {format=>0});
    print_output($output);
}

###############################################################################
# SHOW commands
###############################################################################

# cmd: show status
sub do_show_status {
    return do_status(@_);
}

# cmd: show log
sub do_show_log {
    my ($conn, $parsed, $args) = @_;
    my $format = 1;

    GetOptionsFromArray($args->{-options},
                'raw!'     => \(my $raw = 0),
                'format!'  => \$format,
                'reverse!' => \(my $reverse = 1),
                'nf'       => sub { $format = 0 },
            ) or return;

    $format &&= !$raw;

    my @args = defined $args->{'nlines'} ? ($args->{'nlines'}) : ();
    my $log = check_send_command($conn, 'get_log', @args) or return;
    if ($format) {
        $log =~ s/^(\S+)\t(\d+)\t/format_time($1,' ')." [$2] "/gme;
    }
    if ($reverse) {
        $log = join("\n", reverse split(/\n/, $log));
    }
    print_output($log);
}

# cmd: show version
sub do_show_version {
    my ($conn, $parsed, $args) = @_;
    GetOptionsFromArray($args->{-options});
    print_output($STATUS->{'version'}."\n");
}

# cmd: show uptime
sub do_show_uptime {
    my ($conn, $parsed, $args) = @_;
    GetOptionsFromArray($args->{-options});

    ($STATUS) = get_status($conn, {raw=>0, format=>1});

    return if !$STATUS;

    print_output(
        sprintf("%s up %s (started: %s)\n",
            strftime("%H:%M:%S", localtime(time)),
            relative_time($STATUS->{'started'}, 0),
            format_time($STATUS->{'started'}),
        )
    );
}

# cmd: show arp
sub do_show_arp {
    my ($conn, $parsed, $args) = @_;

    my $filter_state;
    my $ip = $args->{'ip'};

    if (defined $ip) {
        if ($ip eq 'all') {
            delete $args->{'ip'};
        }
    }

    my ($opts, $output, $tag_fmt) =
        shared_show_arp_ip($conn, 'get_arp', $parsed, $args);

    defined $output or return;

    if (!$$opts{format}) {
        print_output($output);
        return;
    }

    my @output;
    if ($$opts{summary}) {
        if ($$opts{header}) {
            push @output, sprintf("%-17s %-17s %-11s %s",
                                  "MAC", "IP", "Epoch", "Time");
        }
        for my $info (sort { $$a{hex_ip} cmp $$b{hex_ip} } @$output) {
            push @output,
                    sprintf("%-17s %-17s %-11d %s",
                        $$info{mac}, $$info{ip}, 
                        $$info{mac_changed},
                        format_time($$info{mac_changed}),
                    );
        }
    }
    else {
        for my $info (sort { $$a{hex_ip} cmp $$b{hex_ip} } @$output) {
            print STDERR "tagfmt: $tag_fmt\n";
            push @output, join('',
                sprintf("$tag_fmt%s\n", 'ip:', $$info{ip}),
                sprintf("$tag_fmt%s\n", 'mac:', $$info{mac}),
                sprintf("$tag_fmt%s (%s) [%d]\n", 'mac changed:',
                        format_time($$info{mac_changed}),
                        relative_time($$info{mac_changed}),
                        $$info{mac_changed}),
            );
        }
    }
    print_output(join("\n", @output));
}

# cmd: show ip
sub do_show_ip {
    my ($conn, $parsed, $args) = @_;

    my $filter_state;
    my $ip = $args->{'ip'};

    if (defined $ip) {
        if ($ip eq 'all') {
            delete $args->{'ip'};
        }
        elsif ($ip =~ /^(?:dead|alive|pending|none)$/i) {
            $filter_state = lc $ip;
            delete $args->{'ip'};
        }
    }

    my ($opts, $output, $tag_fmt) =
        shared_show_arp_ip($conn, 'get_ip', $parsed, $args);

    defined $output or return;

    if (!$$opts{format}) {
        print_output($output);
        return;
    }

    my @output;
    if ($$opts{summary}) {
        if ($$opts{header}) {
            push @output, sprintf("%-17s %-12s %7s %12s %7s",
                                    "IP", "State", "Queue",
                                    "Rate (q/min)", "Updated");
        }
        for my $info (sort { $$a{hex_ip} cmp $$b{hex_ip} } @$output) {
            next if defined $filter_state && lc $$info{state} ne $filter_state;
            push @output,
                    sprintf("%-17s %-12s %7d %8.3f     %s",
                            $$info{ip}, $$info{state}, $$info{queue},
                            $$info{rate},
                            format_time($$info{state_changed}),
                    );
        }
    }
    else {
        for my $info (sort { $$a{hex_ip} cmp $$b{hex_ip} } @$output) {
            next if defined $filter_state && $$info{state} ne $filter_state;
            push @output, join('',
                sprintf("$tag_fmt%s\n", 'ip:', $$info{ip}),
                sprintf("$tag_fmt%s\n", 'state:', $$info{state}),
                sprintf("$tag_fmt%d\n", 'queue:', $$info{queue}),
                sprintf("$tag_fmt%0.2f\n", 'rate:', $$info{rate}),
                sprintf("$tag_fmt%s (%s) [%d]\n", 'state changed:',
                        format_time($$info{state_changed}),
                        relative_time($$info{state_changed}),
                        $$info{state_changed}),
                sprintf("$tag_fmt%s (%s) [%d]\n", 'last queried:',
                        format_time($$info{last_queried}),
                        relative_time($$info{last_queried}),
                        $$info{last_queried}),
            );
        }
    }
    print_output(join("\n", @output));
}

# ($opts, $output, $tag_fmt) =
#       shared_show_arp_ip($conn, $command, $parsed, $args);
#
#   Executes the specified command and parses the result, translating
#   hex strings to ip and mac addresses where necessary.
#
#   Parameters:
#       $conn       connection handle
#       $command    base command to execute
#       $parsed     ref to list of already parsed words
#       $args       ref to hash with parameters
#
#   Return values:
#       $opts       ref to hash with key=>val options from the @$args
#       $output     either a string (in case of --noformat or --raw),
#                   or a reference to an array of output records. Each
#                   record is a hash (ref) containing key=>value pairs.
#       $tag_fmt    printf format string for the largest "key" string,
#                   e.g. "%-20s".
#
sub shared_show_arp_ip {
    my ($conn, $command, $parsed, $args) = @_;
    my %opts = (
            'header'  => 1,
            'format'  => 1,
            'summary' => 1,
            'raw'     => 0,
        );

    GetOptionsFromArray($args->{-options},
            'header!'  => \$opts{header},
            'raw!'     => \$opts{raw},
            'format!'  => \$opts{format},
            'long!'    => sub { $opts{summary} = !$_[1] },
            'summary!' => sub { $opts{summary} = $_[1] },
            'nf'       => sub { $opts{format}  = 0  },
            'nh'       => sub { $opts{header}  = 0  },
        ) or return;

    $opts{format} &&= !$opts{raw};

    my $reply = '';
    if ($args->{'ip'}) {
        my $arg_count = 0;
        $reply = expand_ip_run($args->{'ip'}, 
                    sub {
                        $arg_count++;
                        return check_send_command($conn, "$command $_[0]");
                    }
                );
        $opts{summary} //= ($arg_count > 1);
    }
    else {
        $reply = check_send_command($conn, $command);
        $opts{summary} //= 1;
    }

    return parse_server_reply($reply, \%opts);
}

# ($output, $tag_fmt) = parse_server_reply($reply, \%opts, [, $key]);
#
#   Helper function for parsing replies from server.
#
#   Parameters:
#
#       $opts     - Hash ref with options:
#                        raw    : don't convert IP/MAC addresses (dfl. false).
#                        format : split up into records (dfl. 1).
#       $reply    - Raw reply from server.
#
#       $key      - Key to store records under. If not given, records will be
#                   stored in an array.
#
#   Returns:
#
#       $opts     - The input hash, but with default values filled in.
#       $output   - Either a string (in case of format=0 or raw=1),
#                   or a reference to an array of output records. Each
#                   record is a hash (ref) containing key=>value pairs.
#       $tag_fmt  - Printf format string for the largest "key" string,
#                   e.g. "%-20s".
#
sub parse_server_reply {
    my $reply = shift;
    my $opts  = @_ ? shift : {};

    %$opts = (
            'format' => 1,
            'raw'    => 0,
            %$opts,
        );

    return if !defined $reply;

    if (!$opts->{raw}) {
        $reply =~ s/\b(tpa|spa|network|ip)=([\da-f]+)\b/"$1=".hex2ip($2)/gme;
        $reply =~ s/\b(tha|sha|mac)=([\da-f]+)\b/"$1=".hex2mac($2)/gme;
    }
    if (!$opts->{format}) {
        return ($opts, $reply, '');
    }

    my @output;
    my $taglen  = 0;
    for my $record (split(/\n\n/, $reply)) {
        my %info = map { split(/=/, $_) } split("\n", $record);

        if (my $ip = $info{'network'}) {
            $info{'hex_network'} = ip2hex($ip);
        }
        if (my $ip = $info{'ip'}) {
            $info{'hex_ip'} = ip2hex($ip);
        }
        if (my $mac = $info{'mac'}) {
            $info{'hex_mac'} = mac2hex($mac);
        }

        push @output, \%info;

        foreach (keys %info) {
            $taglen = length($_) if length($_) > $taglen;
        }
    }
    $taglen++;
    my $tag_fmt = "%-${taglen}s ";

    return ($opts, \@output, $tag_fmt);
}

###############################################################################
# CLEAR commands
###############################################################################

# cmd: clear ip
sub do_clear_ip {
    my ($conn, $parsed, $args) = @_;

    my $ip = $args->{'ip'};

    if ($ip eq 'all') {
        return check_send_command($conn, 'clear_ip_all') or return;
    }

    expand_ip_run($ip,
                  sub {
                      return check_send_command($conn, "clear_ip $_[0]");
                  }
                );
    return;
}

# cmd: clear arp
sub do_clear_arp {
    my ($conn, $parsed, $args) = @_;

    my $ip = $args->{'ip'};

    expand_ip_run($ip, 
                  sub {
                      return check_send_command($conn, "clear_arp $_[0]");
                  }
                );
    return;
}

###############################################################################
# SET commands
###############################################################################

sub do_set_generic {
    my %opts      = @_;
    my $conn      = $opts{-conn};
    my $arg       = $opts{-val};
    my $name      = $opts{-name};
    my $type      = $opts{-type};
    my $unit      = $opts{-unit}    // '';
    my $command   = $opts{-command} // "set_$name";

    $command =~ s/[-\s]+/_/g;

    GetOptionsFromArray($opts{-options}) or return;

    my $reply = check_send_command($conn, $command, $arg) or return;

    my ($opts, $output, $tag) = parse_server_reply($reply);
    my $old = $output->[0]->{old};
    my $new = $output->[0]->{new};

    my $fmt = '%s';
    given ($type) {
        when ('boolean') {
            $old = $old ? 'yes' : 'no';
            $new = $new ? 'yes' : 'no';
            $type = '%s';
        }
        when ('int') {
            $type = '%d';
        }
        when ('float') {
            $fmt = '%0.2f';
        }
    }
    print_output(sprintf("%s changed from $fmt to $fmt%s",
                         $name, $old, $new, $unit));
}

# cmd: set queuedepth
sub do_set_queuedepth {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'queuedepth',
                   -val     => $args->{'num'},
                   -options => $args->{-options},
                   -type    => 'int');
}

# cmd: set max-pending
sub do_set_max_pending {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'max-pending',
                   -val     => $args->{'num'},
                   -options => $args->{-options},
                   -unit    => ' secs',
                   -type    => 'integer');
}

# cmd: set max-rate
sub do_set_max_rate {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'max-rate',
                   -val     => $args->{'rate'},
                   -options => $args->{-options},
                   -unit    => ' q/min',
                   -type    => 'float');
}

# cmd: set learning
sub do_set_learning {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'learning',
                   -val     => $args->{'secs'},
                   -options => $args->{-options},
                   -unit    => ' secs',
                   -type    => 'int');
}

# cmd: set flood-protection
sub do_set_flood_protection {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'flood-protection',
                   -val     => $args->{'rate'},
                   -options => $args->{-options},
                   -unit    => ' q/sec',
                   -type    => 'float');
}

# cmd: set proberate
sub do_set_proberate {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'proberate',
                   -val     => $args->{'rate'},
                   -options => $args->{-options},
                   -unit    => ' q/sec',
                   -type    => 'float');
}

# cmd: set dummy
sub do_set_dummy {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'dummy',
                   -val     => $args->{'bool'},
                   -options => $args->{-options},
                   -type    => 'bool');
}
 
# cmd: set sweep period
sub do_set_sweep_period {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'sweep period',
                   -command => 'set_sweep_sec',
                   -val     => $args->{'secs'},
                   -options => $args->{-options},
                   -unit    => ' secs',
                   -type    => 'int');
}

# cmd: set sweep age
sub do_set_sweep_age {
    my ($conn, $parsed, $args) = @_;

    do_set_generic(-conn    => $conn,
                   -name    => 'sweep age',
                   -val     => $args->{'secs'},
                   -options => $args->{-options},
                   -unit    => ' secs',
                   -type    => 'int');
}

sub do_set_ip_generic {
    my %opts      = @_;
    my $conn      = $opts{-conn};
    my $arg       = $opts{-val};
    my $ip        = ip2hex($opts{-ip});
    my $name      = $opts{-name} // 'arg';
    my $type      = $opts{-type} // 'string';
    my $unit      = $opts{-unit} // '';
    my $command   = $opts{-command} // "set_ip_$name";

    $command =~ s/[-\s]+/_/g;

    GetOptionsFromArray($opts{-options}) or return;

    my @command_args = ($command, $ip);
    push(@command_args, $arg) if defined $arg;
    my $reply = check_send_command($conn, @command_args) or return;

    my ($opts, $output, $tag) = parse_server_reply($reply);
    my $old = $output->[0]->{old};
    my $new = $output->[0]->{new};

    my $fmt = '%s';
    given ($type) {
        when ('boolean') {
            $old = $old ? 'yes' : 'no';
            $new = $new ? 'yes' : 'no';
            $type = '%s';
        }
        when ('int') {
            $type = '%d';
        }
        when ('float') {
            $fmt = '%0.2f';
        }
    }
    print_output(sprintf("%s: %s changed from $fmt to $fmt%s",
                         $output->[0]->{ip},
                         $name, $old, $new, $unit));
}

# cmd: set ip pending
sub do_set_ip_pending {
    my ($conn, $parsed, $args) = @_;

    do_set_ip_generic(-conn    => $conn,
                      -command => 'set_pending',
                      -name    => 'state',
                      -val     => $args->{'state'} // 0,
                      -ip      => $args->{'ip'},
                      -options => $args->{-options},
                      -type    => 'string');
}

# cmd: set ip dead
sub do_set_ip_dead {
    my ($conn, $parsed, $args) = @_;

    do_set_ip_generic(-conn    => $conn,
                      -command => 'set_dead',
                      -name    => 'state',
                      -ip      => $args->{'ip'},
                      -options => $args->{-options});
}

# cmd: set ip alive
sub do_set_ip_alive {
    my ($conn, $parsed, $args) = @_;

    do_set_ip_generic(-conn    => $conn,
                      -command => 'set_alive',
                      -name    => 'state',
                      -arg     => $args->{'mac'},
                      -ip      => $args->{'ip'},
                      -options => $args->{-options});
}

# cmd: set ip mac
#
#   Alias for "set ip alive" with a mandatory MAC argument.
sub do_set_ip_mac {
    my ($conn, $parsed, $args) = @_;

    return do_set_ip_alive($conn, $parsed, $args);
}

###############################################################################
# STATUS command
###############################################################################

# cmd: status
sub do_status {
    my ($conn, $parsed, $args) = @_;
    my $format = 1;

    my %opts = ( raw => 0, format => 1 );

    GetOptionsFromArray($args->{-options},
            'raw!'     => \$opts{raw},
            'format!'  => \$opts{format},
            'nf'       => sub { $opts{format} = 0 },
        ) or return;

    $opts{format} &&= !$opts{raw};

    my $reply = check_send_command($conn, 'get_status') or return;

    my ($opts, $output, $tag) = parse_server_reply($reply, \%opts);

    if (!$opts->{format}) {
        return print_output($output);
    }
    my $info = $output->[0];
    print_output(
        sprintf("$tag%s\n", 'id:', $$info{id}),
        sprintf("$tag%d\n", 'pid:', $$info{pid}),
        sprintf("$tag%s\n", 'version:', $$info{version}),
        sprintf("$tag%s [%d]\n", 'date:',
                format_time($$info{date}), $$info{date}),
        sprintf("$tag%s [%d]\n", 'started:',
                format_time($$info{started}), $$info{started}),
        sprintf("$tag%s/%d\n", 'network:',
                $$info{network}, $$info{prefixlen}),
        sprintf("$tag%s\n", 'interface:', $$info{interface}),
        sprintf("$tag%s\n", 'IP:', $$info{ip}),
        sprintf("$tag%s\n", 'MAC:', $$info{mac}),
        sprintf("$tag%d\n", 'queue depth:', $$info{queue_depth}),
        sprintf("$tag%0.2f q/min\n", 'max rate:', $$info{max_rate}),
        sprintf("$tag%0.2f q/sec\n", 'flood protection:',
                $$info{flood_protection}),
        sprintf("$tag%d\n", 'max pending:', $$info{max_pending}),
        sprintf("$tag%d secs\n", 'sweep period:', $$info{sweep_period}),
        sprintf("$tag%d secs\n", 'sweep age:', $$info{sweep_age}),
        sprintf("$tag%d pkts/sec\n", 'proberate:', $$info{proberate}),
        sprintf("$tag%s (in %d secs) [%d]\n", 'next sweep:',
                format_time($$info{next_sweep}),
                $$info{next_sweep}-$$info{date},
                $$info{next_sweep}),
        sprintf("$tag%s\n", 'learning', 
                    $$info{learning}?"yes ($$info{learning} secs)":'no'),
        sprintf("$tag%s\n", 'dummy', $$info{dummy}?'yes':'no'),
    );
}

# ($output, $tag_fmt) = get_status($conn, \%opts);
#
#   Helper function for status. Similar to the ip/arp thing.
#
sub get_status {
    my ($conn, $opts) = @_;

    my $reply;
    
    if ($conn) {
        $reply = check_send_command($conn, 'get_status') or return;
    }
    else {
        $reply = qq{id=arpsponge-test\n}
               . qq{version=0.0\n}
               . qq{pid=0\n}
               . qq{network=}.ip2hex('192.168.1.0').qq{\n}
               . qq{prefixlen=24\n}
               ;
    }

    if (!$$opts{raw}) {
        $reply =~ s/^(network|ip)=([\da-f]+)$/"$1=".hex2ip($2)/gme;
        $reply =~ s/^(mac)=([\da-f]+)$/"$1=".hex2mac($2)/gme;
    }

    if (!$$opts{format}) {
        return ($reply, '%s ');
    }

    my %info = map { split(/=/, $_) } split("\n", $reply);
    my $taglen = 0;
    foreach (keys %info) {
        $taglen = length($_) if length($_) > $taglen;
    }
    $taglen++;
    return (\%info, "%-${taglen}s ");
}

###############################################################################
# Initialisation
###############################################################################

sub initialise {
    my ($sockname, $interface);
    GetOptions(
        'verbose+'    => \$opt_verbose,
        'debug!'      => \$opt_debug,
        'help|?'      =>
            sub { pod2usage(-msg => $app_header, -exitval=>0, -verbose=>0) },
        'interface=s' => \$interface,
        'rundir=s'    => \$rundir,
        'socket=s'    => \$sockname,
        'test!'       => \$opt_test,
        'manual'      => sub { pod2usage(-exitval=>0, -verbose=>2) },
    ) or pod2usage(-exitval=>2);

    $opt_verbose += $opt_debug;

    if ($sockname) {
        if ($interface) {
            die "$0: --socket and --interface are mutually exclusive\n";
        }
    }
    elsif ($interface) {
        $sockname = "$rundir/$interface/control";
    }
    else {
        for my $entry (glob("$rundir/*")) {
            if (-S "$entry/control") {
                $sockname = "$entry/control";
                last;
            }
        }
        if (!$sockname) {
            die "$0: cannot find sponge instance in $rundir\n";
        }

    }

    $M6::ReadLine::TYPES{'ip-range'} = {
            'verify'   => \&check_ip_range_arg,
            'complete' => \&complete_ip_range,
        };
    $M6::ReadLine::TYPES{'ip-filter'} = {
            'verify'   => \&check_ip_filter_arg,
            'complete' => \&complete_ip_filter,
        };

    $INTERACTIVE = -t STDIN && -t STDOUT;
    $opt_verbose //= $INTERACTIVE && !@ARGV;

    return ($sockname, [@ARGV]);
}

sub do_signal {
    die("\n** $_[0] signal -- exiting\n");
}

##############################################################################

Main();

__END__

=head1 NAME

asctl - Arp Sponge ConTroL utility

=head1 SYNOPSIS

B<asctl>
[B<--verbose>]
[B<--rundir>=I<dir>]
[B<--interface>=I<ifname>]
[B<--socket>=I<sock>]
[I<command> ...]

=head1 DESCRIPTION

The C<asctl> program connects to a running L<arpsponge(8)|arpsponge>'s control
socket, and executes commands that either come from standard input, or from
the command line.

By default, the program connects to the first control socket it finds in
F<@SPONGE_VAR@> (see L<FILES|/FILES>), but see L<OPTIONS|/OPTIONS> below
for ways to override this.

=head1 OPTIONS

=over

=item X<--verbose>B<--verbose>

The C<--verbose> flag causes the program to be a little more talkative.

=item B<--rundir>=I<dir>

Override the default top directory for the L<arpsponge> control files.
See also L<FILES|/FILES> below.

=item B<--interface>=I<ifname>

Connect to the L<arpsponge> instance for interface I<ifname>.

=item B<--socket>=I<sock>

Explicitly specify the path of the control socket to connect to. Mutually
exclusive with L<--interface|/--interface>.

=back

=head1 COMMANDS

    quit
    ping [<count> [<delay>]]
    sponge <ip>
    unsponge <ip>
    status

    clear ip { all | <ip> ... }
    clear arp <ip> ...

    set max-pending <num>
    set queuedepth <num>
    set max-rate <rate>
    set flood-protection <rate>
    set learning <secs>
    set proberate <rate>
    set dummy <bool>
    set sweep age <secs>
    set sweep period <secs>

    set ip ...

    show status
    show version
    show uptime
    show log [ <count> ]
    show arp [ { all | <ip> ... } ]
    show ip [ { all | alive | dead | pending | <ip> ... } ]

=head1 COMMAND OPTIONS

Most C<show> commands accept the following options:

=over

=item X<--raw>X<--noraw>B<--raw>, B<--noraw>

Don't translate timestamps, IP addresses or MAC addresses. Implies
C<--noformat>.

=item X<--format>B<--format>

=item X<--nf>X<--noformat>B<--nf>, B<--noformat>

=back

=head1 FILES

=over

=item F<@SPONGE_VAR@>

Default top-level directory location for per-interface control sockets:
the L<arpsponge> on interface I<ifname> will have its control socket at
F<@SPONGE_VAR@/>I<ifname>F</control>.

=back

=head1 SEE ALSO

L<arpsponge(8)|arpsponge>,
L<asctl(8)|asctl>,
L<tail(1)|tail>,
L<perl(1)|perl>.

=head1 AUTHOR

Steven Bakker E<lt>steven.bakker@ams-ix.netE<gt>, AMS-IX B.V.; 2011.
