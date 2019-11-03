#!/usr/bin/perl

use warnings;
use strict;

use HTTP::Server::Simple::CGI;
use DBI;
use Data::GUID;
use IO::Socket::INET;
use Data::Dumper;

my $LOGFILE = ">>/tmp/auth_service.log";

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

# Turn off output buffering.
# This is so stuff gets dumped to the console / app log immediately instead of somewhat after the event.
select STDERR;
$| = 1;

select STDOUT;
$| = 1;

# Connect to the config database
print "Connecting to config database ...\n";

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=" . $config_dir . "/broadway_proxy_config.db"
  , undef # username
  , undef # password
  , {}    # options hash
) || die( DBI->errstr );

my $auth_service_port;

# Fetch our port
my $sth = $dbh->prepare( "select value from simple_config where key = 'auth_service_port'" )
  || die( DBI->errstr );

$sth->execute()
  || die( $sth->errstr );

if ( my $row = $sth->fetchrow_hashref ) {
    $auth_service_port = $row->{value};
} else {
    die( "Couldn't find auth service port in simple_config!" );
}

# Fetch the user app service port

my $user_app_service_port;

$sth = $dbh->prepare( "select value from simple_config where key = 'user_app_service_port'" )
  || die( DBI->errstr );

$sth->execute()
  || die( $sth->errstr );

if ( my $row = $sth->fetchrow_hashref ) {
    $user_app_service_port = $row->{value};
} else {
    die( "Couldn't find auth service port in simple_config!" );
}

########################################################################################################
# This code is based off the following example:
# https://renenyffenegger.ch/notes/development/languages/Perl/modules/HTTP/Server/Simple/CGI/webserver
########################################################################################################

{
    
    package WebServer;
    use warnings;
    use strict;
    
    use base 'HTTP::Server::Simple::CGI';

    use File::Slurp; # import read_file
    use Data::Dumper;
    use Digest::MD5 qw(md5_hex);
        
    my $nl = "\x0d\x0a";
    my $name_provided = '';
    my $password = '';
    my $message = '';
    my $auth_cookie_value = undef;

    my $root = 'LoginForm';
    
    chdir( $root );
    
    sub print_header {
        
        my $content_type = shift;

        print "HTTP/1.0 200 OK$nl";
        print "Content-Type: $content_type; charset=utf-8$nl";
        
        if ( $auth_cookie_value ) {
            print "Cookie: auth_key=$auth_cookie_value;$nl";
            print "Location: /$nl";
        }
        
        print $nl;
        
    }
    
    sub serve_file {
        
        my $path_relative = shift;
        my $content_type  = shift;
        my $cgi = shift;
        my $auth_cookie = shift;

        print_header($content_type);

        if ( $path_relative =~ /\.htm$/  or $path_relative =~ /\.html$/ ) {

            #############################################################################################################
            # For some reason it needs to print some non white space to STDOUT, but not for images only text based files.
            # I would like to get rid of this print statement but when i do all the styling goes out that window.
            #############################################################################################################
            print STDOUT "<div></div>";
            #print STDOUT "<div>$message</div>";

            $message = '';
        }

        if (-e $path_relative) {
           print read_file($path_relative, binmode => ":raw");
        }
        else {
           print "file $path_relative not found";
        }


    }

    sub handle_request {
        
        my $self = shift;
        my $cgi  = shift;
        
        my $auth_cookie = $cgi->cookie();        
        my $path = $cgi->path_info;
        
        open LOG , $LOGFILE
            || die( $! );
        
        select LOG;
        $| = 1;
        
        print LOG "Opened log ...\n";
        
        select STDOUT;
        
        if ( $cgi->param( 'email' ) ) {
            
            print LOG "Found param email: [" . $cgi->param( 'email' ) . "]\n";
            
            $name_provided = $cgi->param( 'email' );
            $password = $cgi->param( 'pass' );
            
            print LOG "Checkpoint 1\n";
            
            ###########################################################################
            # Authenticate against users, set last_authenticated, auth_key & port.
            ###########################################################################
            
            my $sql = "select * from users where username = ? and password = ?";
            
            my $sth = $dbh->prepare( $sql )
                || print LOG $dbh->errstr;
            
            print LOG $sth->{Statement} . "\n";
            
            $sth->execute( $name_provided, md5_hex( $password ) )
                || print LOG $sth->errstr . "\n";
            
            print LOG "Checkpoint 2\n";
            
            my $row = $sth->fetchrow_hashref;
            
            $sth->finish();
            
            if ( $row ) {
                
                print LOG "Got auth row:\n" . Dumper( $row ) . "\n";
                
                $message = "name: $row->{username}\n";

                my $auth_token = Data::GUID->new;
                my $auth_key = $auth_token->as_string;
                
                print LOG "Checkpoint 3\n";
                              
                # update the auth table with last_authenticated, auth_key & port
                $sql = <<'END_SQL';
                  update users
                  set
                    last_authenticated = datetime('now', 'localtime'),
                    auth_key = ?,
                    port = ?,
                    display_number = null
                  where username = ? and password = ?
END_SQL
                my $sth = $dbh->prepare( $sql )
                  || print LOG "DB error: " . $dbh->errstr . "\n";

                my $port = $user_app_service_port;

                # reconnect to last saved db session
                if ($row->{auth_key} and $row->{port}) {
                    $auth_key = $row->{auth_key};
                    $port = $row->{port};
                }

                print LOG "Checkpoint 4\n";
                
                $sth->execute(
                    $auth_key
                  , $port
                  , $name_provided
                  , md5_hex( $password )
                ) || print LOG "DB error: " . $sth->errst . "\n";
                
                $sth->finish();
                
                print LOG "Checkpoint 5\n";
                
                $auth_cookie = $cgi->cookie(
                   -name  => 'auth_key',
                   -value => $auth_key
                );
                
                print LOG "Checkpoint 6\n";
                
                print "HTTP/1.0 200 OK$nl";
                
                print $cgi->header(
                    {
                        -cookie => $auth_cookie
                      , -refresh => 1
                    }
                );
                
                print LOG "Exiting handle_request()\n";
                
                close LOG;
                
                return;
                
            }
            
        } else {
            
            print LOG "No matching record in users table ...\n";
            $name_provided = 'nothing provided';
            
        }

        if ( $path eq '/' ) {
          if (-e 'index.html') {
            serve_file ("index.html", 'text/html', $cgi);
          }
          else {
            print join "\n", glob('*');
          }
          return;
        }

      #  See http://de.selfhtml.org/diverses/mimetypen.htm for Mime Types.

        if ($path =~ /\.htm$/  or $path =~ /\.html$/) {
          serve_file (".$path", 'text/html', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.js$/ ) {
          serve_file (".$path", 'application/javascript', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.txt$/) {
          serve_file (".$path", 'text/plain', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.js$/ ) {
          serve_file (".$path", 'application/javascript', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.png$/) {
          serve_file (".$path", 'image/png', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.jpg$/ or $path =~ /\.jpeg/) {
          serve_file (".$path", 'image/jpeg', $cgi, $auth_cookie);
          return;
        }
        if ($path =~ /\.ico$/) {
          serve_file (".$path", 'image/x-icon', $cgi, $auth_cookie);
          return;
        }

        print STDERR "Unknown Mime type for $path\n";

        serve_file( ".$path", 'text/plain', $cgi, $auth_cookie);

    }

}

my $pid = WebServer->new( $auth_service_port )->run;
