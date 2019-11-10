#!/usr/bin/perl
use strict;
use warnings FATAL => 'all';
use Data::Dumper;

my $pid_map = {};

my $LOGFILE = ">>/tmp/session_manager.log";
my $LOG;

open $LOG , $LOGFILE
    || die( "Failed to open session manager log:\n" . $! );

use Getopt::Long;

my ( $display , $port , $command );

GetOptions(
    'display=i'            => \$display
  , 'port=i'               => \$port
  , 'command=s'            => \$command
);

print $LOG "Got:\n"
    . " display: [$display]\n"
    . " port:    [$port]\n"
    . " command: [$command]\n\n";

sub fork_it {
    
    my ( $type , $args , $display ) = @_;
    
    my $pid = fork;
    
    if ( $pid ) {
        $pid_map->{$pid} = $type;
    } elsif ( defined ( $pid ) ) {
        my $cmd_string = join(' ', @{$args});
        if ( $display ) {
            $cmd_string = "GDK_BACKEND=broadway BROADWAY_DISPLAY=:$display $cmd_string";
        }
        print $LOG "Executing: [$cmd_string]\n";

        # redirect exec process output to $LOGFILE
        open STDOUT, $LOGFILE or die $!;
        open STDERR, $LOGFILE or die $!;

        exec( $cmd_string )
          or print $LOG "Couldn't exec $cmd_string ($!)\n";
    } else {
        die( 'Failed to fork: ' . $! );
    }
    
}

my $args = [ 'broadwayd' , '-p' , $port , ':' . $display ];
fork_it( 'broadwayd', $args );

sleep( 2 );

$args = [ $command ];
fork_it( $command  , $args , $display );

my $wait_pid = wait || die('Failed to wait: ' . $!);

if ( $wait_pid ) {
    print $LOG "Caught PID [$wait_pid] exiting\n";
    print $LOG "  ... " . $pid_map->{$wait_pid} . "\n";
    print $LOG "Whole map:\n" . Dumper( $pid_map ) . "\n";
    # kill other process
    foreach my $key ( keys %{ $pid_map } ) {
        if ( $wait_pid ne $key ) {
            kill "HUP" , $key;
        }
    }
}

close $LOG
    || die( "Failed to close session manager log:\n" . $! );
