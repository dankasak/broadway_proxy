#!/usr/bin/perl
#
# Peteris Krumins (peter@catonmat.net)
# http://www.catonmat.net  --  good coders code, great reuse
#
# A simple TCP proxy that implements IP-based access control
#
# Written for the article "Turn any Linux computer into SOCKS5
# proxy in one command," which can be read here:
#
# http://www.catonmat.net/blog/linux-socks5-proxy
#
##############################################################
#
# Modified by Dan Kasak ( d.j.kasak.dk@gmail.com )
# http://tesla.duckdns.org
#
# Added some hacks for proxying based on the value in a cookie,
# as a proof-of-concept transparent proxy for Gtk+ / broadway

use warnings;
use strict;

use Data::Dumper;
use DBI;
use IO::Socket;
use IO::Select;

my $LOGFILE = ">>/tmp/broadway.log";

# Determine the config base
my $config_dir;

if ( $ENV{'XDG_CONFIG_HOME'} ) {
    $config_dir = $ENV{'XDG_CONFIG_HOME'};
} else {
    $config_dir = $ENV{"HOME"} . "/.broadway_session_manager";
}

print "Config dir: [$config_dir]\n";

if ( ! -d $config_dir ) {
    mkdir( $config_dir )
        || die( "Failed to create config directory [$config_dir]:\n" . $! );
}

# Connect to the config database
print "Connecting to config database ...\n";

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=" . $config_dir . "/broadway_proxy_config.db"
  , undef # username
  , undef # password
  , {}    # options hash
) || die( DBI->errstr );

# Fetch config db settings
my ( $proxy_port , $auth_service_port );

my $sth = $dbh->prepare(
    "select value from simple_config where key = 'proxy_port'" )
  || die( DBI->errstr );

$sth->execute()
  || die( $sth->errstr );

if ( my $row = $sth->fetchrow_hashref ) {
    $proxy_port = $row->{value};
} else {
    die( "Couldn't find proxy_port in simple_config!" );
}

$sth = $dbh->prepare(
    "select value from simple_config where key = 'auth_service_port'" )
  || die( DBI->errstr );

$sth->execute()
  || die( $sth->errstr );

if ( my $row = $sth->fetchrow_hashref ) {
    $auth_service_port = $row->{value};
} else {
    die( "Couldn't find auth_service_port in simple_config!" );
}

################################################################

my $ioset = IO::Select->new;
my %socket_map;

my $debug = 0;

sub new_server {
    my ( $host, $port ) = @_;
    my $server = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => $port,
        ReuseAddr => 1,
        Listen    => 100
    ) || die "Unable to listen on $host:$port: $!";
}

sub close_connection {
    
    my $client = shift;
    my $client_ip = client_ip( $client );
    
    if ( ! $client_ip ) {
        warn "close_connection() received an undef IP from client_ip()";
        return;
    }
    
    my $remote = $socket_map{ $client };
    
    foreach my $socket ( $client , $remote ) {
        
        if ( ref $socket eq 'ConnectionFuture' ) {
            $socket->disconnect;
        } else {
            $ioset->remove( $socket );
        }
    }
    
    delete $socket_map{ $client };
    delete $socket_map{ $remote };
    
    $client->close;
    $remote->close;
    
    print "Connection from $client_ip closed.\n" if $debug;
    
}

sub client_ip {
    my $client = shift;
    my $sockaddr = $client->sockaddr();
    if ( $sockaddr ) {
        return inet_ntoa($client->sockaddr);
    } else {
        warn "Couldn't resolve sockaddr / ip from client!";
        return undef;
    }
}

print "Starting broadway_proxy on http://0.0.0.0:$proxy_port\n";
my $server = new_server( '0.0.0.0' , $proxy_port );
$ioset->add( $server );

while (1) {
    for my $socket ($ioset->can_read) {
        if ($socket == $server) { # $socket is what we're reading from ... $server is our listener. if socket == server, we're reading, and need to create a new target
            ConnectionFuture->new( $server );
        }
        else {
            next unless exists $socket_map{$socket};
            my $remote = $socket_map{$socket};
            my $buffer;
            my $read = $socket->sysread($buffer, 4096);
            if ($read) {
                $remote->syswrite($buffer);
            }
            else {
                close_connection($socket);
            }
        }
    }
}

package ConnectionFuture;

use HTTP::Request;

my $LOG;

sub new {
    
    my ( $class, $server ) = @_;
    
    my $self = {
        server  => $server
    };
    
    bless $self, $class;
    
    open( $LOG , $LOGFILE )
        || die( $! );
    
    select $LOG;
    $| = 1;
    
    print $LOG "Opened log ...\n";
    
    select STDOUT;
    
    $self->{client} = $self->{server}->accept;
    
    $socket_map{ $self->{client} } = $self;
    $socket_map{ $self->{server} } = $self->{client};
    
    $ioset->add( $self->{client} );
    
    return $self;
    
}

sub cookie_to_port {
    
    my ( $self , $cookie ) = @_;
    
    my $auth_key;
    
    print $LOG "Cookie:\n" . $cookie . "\n";
    
    if ( $cookie =~ /auth_key=(\w*-\w*-\w*-\w*-\w*)/ ) {
        $auth_key = $1;
        print $LOG "Found auth key in cookie: $auth_key\n";
    }
    
    if ( $auth_key ) {
        # The user has allegedly logged in. Try to map their auth key to a port ...
        my $sth = $dbh->prepare(
            "select * from users where auth_key = ?"
        ) || die( $dbh->errstr );
        
        $sth->execute( $auth_key )
            || die( $sth->errstr );
        
        if ( my $row = $sth->fetchrow_hashref() ) {        
            print $LOG "Successfully mapped auth key to port $row->{port}\n";
            return $row->{port};
        } else {
            print $LOG "Auth key not found in DB. Back to the login screen ...\n";
            return $auth_service_port;
        }
    } else {
        print $LOG "Didn't find an auth key ... presenting the login screen ...\n";
        return $auth_service_port;
    }
    
}

sub syswrite {
    
    my ( $self, $buffer ) = @_;
    
    if ( ! exists $self->{remote} ) {
        
        my $host = 'localhost';
        
        my $request = HTTP::Request->parse( $buffer );
        my $uri     = $request->uri();
        my $headers = $request->headers;
        my $cookie  = $headers->{cookie};
        
        print $LOG "Request URI: [$uri]\n";
        
        my $port;
        
        if ( $cookie ) {
            $port = $self->cookie_to_port( $cookie );
        } else {
            print $LOG "No cookies for current request\n";
        }
        
        if ( ! $port ) {
            print $LOG "Couldn't resolve port. Redirecting to auth_service\n";
            $port = $auth_service_port;
        }
        
        print $LOG "Opening socket to host [$host] port [$port]\n";
        
        eval {
            $self->{remote} = IO::Socket::INET->new(
                PeerAddr => $host
              , PeerPort => $port
            ) || die "Unable to connect to $host:$port: $!";
        };
        
        my $err = $@;
        
        if ( $err ) {
            
            my $sth = $dbh->prepare(
                "update users set auth_key = null , port = null , display_number = null where port = ?"
            ) || print $LOG "Failed to clear out stale port + auth details:\n" . $dbh->errstr;
            
            if ( $sth ) {
                $sth->execute( $port )
                    || print $LOG "Failed to clear out stale port + auth details:\n" . $dbh->errstr;
            }
            
            $self->{remote} = IO::Socket::INET->new(
                PeerAddr => $host
              , PeerPort => $auth_service_port
            ) || die "Unable to connect to $host:$auth_service_port: $!";

        }
        
        print $LOG "Socket opened ...\n";
        
        $socket_map{ $self->{remote} } = $self->{client};
        
        $ioset->add( $self->{remote} );
        
    }
    
    if ( $self->{remote} ) {
        $self->{remote}->syswrite( $buffer );
    }
    
}

sub disconnect {
    
    my $self = shift;
    
    $ioset->remove( $self->{client} );
    $ioset->remove( $self->{remote} );
    
}

sub close {
    
    my $self = shift;
    
    $self->{client}->close;
    
    if ( $self->{remote} ) {
        $self->{remote}->close;
    }
    
}

1;
