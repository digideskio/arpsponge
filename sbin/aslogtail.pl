#!@PERL@ -I../lib
# ============================================================================
#
#         File:  aslogtail.pl
#
#        Usage:  see POD at end
#
#  Description:  ArpSponge Log Tail
#
#       Author:  Steven Bakker (SB), <steven.bakker@ams-ix.net>
#      Created:  2011-03-24 15:38:13 CET
#
#   Copyright 2011-2016 AMS-IX B.V.; All rights reserved.
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
use Getopt::Long qw( GetOptions );
use Pod::Usage;
use M6::ARP::Control::Client;
use M6::ARP::Util qw( :all );

my $SPONGE_VAR    = '@SPONGE_VAR@';
my $CONN          = undef;

# Values set on the Command Line.
my $opt_verbose   = undef;
my $rundir        = $SPONGE_VAR;
my $HISTFILE      = "$::ENV{HOME}/.$0_history";

my $VERSION    = '@RELEASE@';
my $app_header = "\nThis is $0, v$VERSION\n\n"
               . "See \"perldoc $0\" for more information.\n"
               ;

sub verbose(@) { print @_ if $opt_verbose; }

sub Main {
    my ($sockname, $raw, $follow, $lines) = initialise();

    verbose "connecting to arpsponge on $sockname\n";
    my $conn = M6::ARP::Control::Client->create_client($sockname)
                or die M6::ARP::Control::Client->error."\n";

    if ($lines) {
        my $reply = $conn->send_command("get_log $lines");
        $reply =~ s/^\[(\S+)\]\s*\Z//m;
        dump_log($raw, $reply);
    }
    if ($follow) {
        while ( my @lines = $conn->read_log_data(-blocking => 1) ) {
            dump_log($raw, @lines);
        }
    }
    $conn->close;
    exit(0);
}

sub dump_log {
    my ($raw, @lines) = @_;
    if ($raw) {
        print @lines;
    }
    else {
        for my $log (@lines) {
            $log =~ s/^(\S+)\t(\d+)\t/format_time($1,' ')." [$2] "/mge;
            print $log;
        }
    }
}

sub initialise {
    my @lines_spec = grep { /^-\d+$/ } @ARGV;
    @ARGV = grep { ! /^-\d+$/ } @ARGV;

    my $lines = 10;
    if (@lines_spec) {
        ($lines) = $lines_spec[$#lines_spec] =~ /^-(\d+)$/;
    }

    GetOptions(
        'verbose'     => \$opt_verbose,
        'help|?'      =>
            sub { pod2usage(-msg => $app_header, -exitval=>0, -verbose=>0) },
        'interface=s' => \(my $interface),
        'rundir=s'    => \$rundir,
        'socket=s'    => \(my $sockname),
        'follow|f'    => \(my $follow = 0),
        'lines=i'     => \$lines,
        'raw!'        => \(my $raw = 0),
        'manual'      => sub { pod2usage(-exitval=>0, -verbose=>2) },
    ) or pod2usage(-exitval=>2);

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
    
    if (@ARGV) {
        pod2usage(-msg => "Too many arguments", -exitval=>2);
    }

    return ($sockname, $raw, $follow, $lines);
}

##############################################################################

Main();

__END__

=head1 NAME

aslogtail - Arp Sponge log tail

=head1 SYNOPSIS

B<aslogtail>
[B<--verbose>]
[B<--rundir>=I<dir>]
[B<--interface>=I<ifname>]
[B<--socket>=I<sock>]
[B<--follow>]
[B<->I<N> | B<--lines>=I<N>]
[B<-->[B<no>]B<raw>]

=head1 DESCRIPTION

The C<aslogtail> program functions like C<tail>, but instead of operating
on a file, it connects to a running L<arpsponge(8)|arpsponge>'s control
socket, reads log events from the daemon and prints them to F<stdout>.

By default, the program connects to the first control socket it finds in
F<@SPONGE_VAR@> (see L<FILES|/FILES>), but see L<OPTIONS|/OPTIONS> below
for ways to override this.

Like L<tail(1)|tail>, it prints 10 lines of log by default and supports
"follow" mode (L<--follow|/--follow>).

Output is in the form of:

  YYYY-MM-DD hh:mm:ss [pid] message

E.g.:

  2011-04-12 16:52:46 [17325] alive=25 dead=37 pending=0 ARP_entries=25

=head1 OPTIONS

=over

=item I<-N>, B<--lines>=I<n>

Print the last I<N> lines of the log.

=item B<--follow>

Stay connected and print each log line as it comes in from the daemon.

=item B<--interface>=I<ifname>

Connect to the L<arpsponge> instance for interface I<ifname>.

=item X<--raw>X<--noraw>B<--raw>, B<--noraw>

If C<--raw> is specified, output will be in the form of:

  <tstamp> <TAB> <pid> <TAB> <message>

Where I<tstamp> is the seconds since epoch, I<pid> is the daemon's process ID
and I<message> is the log message.

=item B<--rundir>=I<dir>

Override the default top directory for the L<arpsponge> control files.
See also L<FILES|/FILES> below.

=item B<--socket>=I<sock>

Explicitly specify the path of the control socket to connect to. Mutually
exclusive with L<--interface|/--interface>.

=item X<--verbose>B<--verbose>

The C<--verbose> flag causes the program to be a little more talkative.


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

Steven Bakker E<lt>steven.bakker@ams-ix.netE<gt>.

=head1 COPYRIGHT

Copyright 2011-2016, AMS-IX B.V.
Distributed under GPL and the Artistic License 2.0.

=cut
