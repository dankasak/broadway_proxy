#!/usr/bin/perl

use warnings;
use strict;

use HTTP::Server::Simple::CGI;
use DBI;
use Data::GUID;
use IO::Socket::INET;
use Data::Dumper;

my $LOGFILE = ">>/tmp/user_app_service.log";

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

sub fetch_simple_config {
    my $key = shift;

    my $sth = $dbh->prepare(
        "select value from simple_config where key = '$key'" )
      || die( DBI->errstr );

    $sth->execute()
      || die( $sth->errstr );

    my $row = $sth->fetchrow_hashref;

    if ( ! defined $row  ) {
        die( "Couldn't find '$key' in simple_config!" );
    }
    return $row->{value};
}

# Fetch config db settings

my $user_app_service_port = fetch_simple_config('user_app_service_port');
my $session_port_first = fetch_simple_config('session_port_first');
my $session_port_last = fetch_simple_config('session_port_last');

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
    my $auth_cookie = undef;

    my $root = 'LoginForm';
    
    chdir( $root );
    
    sub print_header {
        
        my $content_type = shift;

        print "HTTP/1.0 200 OK$nl";
        print "Content-Type: $content_type; charset=utf-8$nl";
        
        if ( $auth_cookie ) {
            print "Cookie: auth_key=$auth_cookie;$nl";
            print "Location: /$nl";
        }
        
        print $nl;
        
    }
    
    sub serve_file {
        
        my $path_relative = shift;
        my $content_type  = shift;
        my $cgi = shift;
        my $auth_cookie = shift;
        my $pattern = shift;
        my $replacement = shift;

        print_header($content_type);

        if ( $path_relative =~ /\.htm$/  or $path_relative =~ /\.html$/ ) {

            #############################################################################################################
            # For some reason it needs to print some non white space to STDOUT, but not for images only text based files.
            # I would like to get rid of this print statement but when i do all the styling goes out that window.
            #############################################################################################################

            # 10.11.19/fp - commented out next line for testing
            #print STDOUT "<div></div>";

            #print STDOUT "<div>$message</div>";
            $message = '';
        }

        if (-e $path_relative) {
            my $contents = read_file($path_relative, binmode => ":raw");
            if ( defined $pattern) {
                $contents =~ s/$pattern/$replacement/g;
            }
            print $contents;
        }
        else {
           print "file $path_relative not found";
        }

    }

    sub find_available_port{

        my $available_port = undef;

        # fetch ports, which might be in use

        my $sql = <<'END_SQL';
          select distinct port from users
          where port is not NULL
END_SQL
        my $sth = $dbh->prepare( $sql )
          || print LOG "DB error: " . $dbh->errstr . "\n";

        $sth->execute()
          || print LOG "DB error: " . $sth->errst . "\n";

        my %portlist;

        while ( my $row = $sth->fetchrow_hashref ) {
            $portlist{$row->{port}} = $row->{port};
        }

        $sth->finish();

        foreach my $port ( $session_port_first .. $session_port_last ) {
            next if $portlist{$port}; # port might be in use

            my $sock = IO::Socket::INET->new(
                LocalAddr => 'localhost'
              , LocalPort => $port
              , Proto     => 'tcp'
              , ReuseAddr => $^O ne 'MSWin32'
            );

            if ( $sock ) {
                close $sock;
                $available_port = $port;
                last;
            }

        }
        return $available_port;
    }

    sub handle_request {
        
        my $self = shift;
        my $cgi  = shift;
        
        my $auth_key = $cgi->cookie( 'auth_key' );
        my $app         = $cgi->param( 'app' );
        my $path        = $cgi->path_info;
        
        open LOG , $LOGFILE
            || die( $! );
        
        select LOG;
        $| = 1;
        
        print LOG "Opened log ...\n";
        
        select STDOUT;
        
        print LOG "auth_key:\n" . Dumper( $auth_key ) . "\ncgi:\n" . Dumper( $cgi ) . "\n";
        
        if ( $app ) {
            print LOG "app selection: $app\n";
        }
        
        if ( $auth_key && $app ) {
            
            print LOG "Found auth_key and app selection. Checking user_apps ...\n";
            
            my $sql = <<'END_SQL';
              select app_command, users.username
              from users
              inner join  user_apps on users.username = user_apps.username
              inner join  apps on user_apps.app_name = apps.app_name
              where auth_key = ?
                and user_apps.app_name = ?
END_SQL
            
            my $sth = $dbh->prepare( $sql )
                || print LOG $dbh->errstr;

            print LOG $sth->{Statement} . "\n";

            $sth->execute( $auth_key , $app )
                || print LOG $sth->errstr . "\n";
            
            if ( my $row = $sth->fetchrow_hashref ) {
                
                print LOG "auth cookie and app selection checks out ... launching session manager ...\n";

                my $port = find_available_port();

                if ( ! defined $port ) {
                    print LOG "Couldn't find a free port in range [$session_port_first..$session_port_last]\n";

                    print_header( 'text/html' );
                    print "Too many open sessions - please try again later.";

                    close LOG;
                    return;
                }

                my $display = $port - $session_port_first + 1;
                
                # Fork a session manager instance
                my $pid = fork();
                
                if ( $pid ) {
                    
                    # We're the master. Update the users table with the port we just grabbed ...
                    $sql = <<'END_SQL';
                      update users
                      set port = ?
                      where auth_key = ?
END_SQL
                    $sth = $dbh->prepare( $sql )
                        || print LOG $dbh->errstr;
                    
                    $sth->execute( $port , $auth_key )
                        || print LOG $sth->errstr;
                    
                    sleep( 5 ); # wait for session manager to launch
                    
                    my $nl = "\x0d\x0a";
                    print "HTTP/1.0 200 OK$nl";
                    print $cgi->header(
                        {
                            -refresh => 1    # hit the proxy again
                        }
                    );
                    
                } elsif ( defined $pid ) {
                    
                    # We're the child
                    
                    my @args = (
                        "/usr/bin/perl"
                      , "../sessionmanager.pl"
                      , "--display=$display"
                      , "--port=$port"
                      , "--username=" . $row->{username}
                      , "--command=" . $row->{app_command}
                    );
                    
                    # redirect exec process output to $LOGFILE
                    open STDOUT, $LOGFILE or die $!;
                    open STDERR, $LOGFILE or die $!;

                    exec( @args )
                        || print LOG "Exec in child failed!\n" . $! . "\n";
                    
                } else {
                    
                    print LOG "Fork of for session manager exec failed!\n" . $! . "\n";
                    
                }
                
            } else {
                print LOG "auth cookie and app selection doesn't match user_apps!\n";
            }
            
        } elsif ( $auth_key ) {
            
            print LOG "Checkpoint 1\n";
            print LOG "Auth cookie located. Looking up ...\n";            
            
            ###########################################################################
            # Authenticate against broadway_user_auth, set last_authenticated, auth_key & port.
            ###########################################################################
            
            my $sql = <<'END_SQL';
              select app_name
              from users
              inner join user_apps on users.username = user_apps.username
              where auth_key = ?
END_SQL
            
            my $sth = $dbh->prepare( $sql )
                || print LOG $dbh->errstr;
            
            print LOG $sth->{Statement} . "\n";
            
            $sth->execute( $auth_key )
                || print LOG $sth->errstr . "\n";
            
            print LOG "Checkpoint 2\n";
            
            my $apps;
            
            while ( my $row = $sth->fetchrow_hashref ) {
                push @{$apps} , $row->{app_name};
            }
            
            $sth->finish();
            
            if ( $path eq '/' and $apps ) {
                
                print LOG "Got authenticated apps\n";
                print LOG "Checkpoint 3\n";
                              
                available_apps_form( $cgi , $apps );

                close LOG;
                return;
                
            }

          #  See http://de.selfhtml.org/diverses/mimetypen.htm for Mime Types.

            if ($path =~ /\.htm$/  or $path =~ /\.html$/) {
              serve_file (".$path", 'text/html', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.js$/ ) {
              serve_file (".$path", 'application/javascript', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.txt$/) {
              serve_file (".$path", 'text/plain', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.js$/ ) {
              serve_file (".$path", 'application/javascript', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.png$/) {
              serve_file (".$path", 'image/png', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.jpg$/ or $path =~ /\.jpeg/) {
              serve_file (".$path", 'image/jpeg', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.ico$/) {
              serve_file (".$path", 'image/x-icon', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.css$/) {
              serve_file (".$path", 'text/css', $cgi, $auth_cookie);
              return;
            }
            elsif ($path =~ /\.(ttf|woff|woff2)$/) {
              serve_file (".$path", 'application/octet-stream', $cgi, $auth_cookie);
              return;
            }

            print STDERR "Unknown Mime type for $path\n";

            # send anyhow
            serve_file( ".$path", 'text/plain', $cgi, $auth_cookie);
        }
    }

    sub available_apps_form {
        
        my $cgi  = shift;
        my $apps = shift;
        
        my $placeholder = "<option>Placeholder for Apps</option>";
        my $options = "";

        # build choice option list
        foreach my $app ( @{$apps} ) {
            $options .= "<option>$app</option>\n";
        }
        
        serve_file (
          "app_chooser.html", 'text/html', 
          $cgi, 
          $auth_cookie,
          $placeholder,
          $options);
    }
}

my $pid = WebServer->new( $user_app_service_port )->run;
