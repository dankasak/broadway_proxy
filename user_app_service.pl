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

my $service_port;

# Fetch our port
my $sth = $dbh->prepare( "select value from simple_config where key = 'user_app_service_port'" )
  || die( DBI->errstr );

$sth->execute()
  || die( $sth->errstr );

if ( my $row = $sth->fetchrow_hashref ) {
    $service_port = $row->{value};
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

    sub find_available_port{

        my $available_port = undef;
        foreach my $port ( 10002 .. 20000 ) { # TODO: port config from sqlite

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
            
            my $sql = "select\n"
                    . "            app_command\n"
                    . "from\n"
                    . "            users\n"
                    . "inner join  user_apps\n"
                    . "                          on users.username = user_apps.username\n"
                    . "inner join  apps\n"
                    . "                          on user_apps.app_name = apps.app_name\n"
                    . "where\n"
                    . "            auth_key = ?\n"
                    . "        and user_apps.app_name = ?";
            
            my $sth = $dbh->prepare( $sql )
                || print LOG $dbh->errstr;

            print LOG $sth->{Statement} . "\n";

            $sth->execute( $auth_key , $app )
                || print LOG $sth->errstr . "\n";
            
            if ( my $row = $sth->fetchrow_hashref ) {
                
                print LOG "auth cookie and app selection checks out ... launching session manager ...\n";
                my $port = find_available_port();
                my $display = $port - 10001; # TODO: port config from sqlite
                
                # Fork a session manager instance
                my $pid = fork();
                
                if ( $pid ) {
                    
                    # We're the master. Update the users table with the port we just grabbed ...
                    $sql = "update users set port = ? where auth_key = ?";
                    
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
                print LOG "auth cookie and app selection don't match what's in user_apps!\n";
            }
            
        } elsif ( $auth_key ) {
            
            print LOG "Checkpoint 1\n";
            print LOG "Auth cookie located. Looking up ...\n";            
            
            ###########################################################################
            # Authenticate against broadway_user_auth, set last_authenticated, auth_key & port.
            ###########################################################################
            
            my $sql = "select app_name from users inner join user_apps on users.username = user_apps.username where auth_key = ?";
            
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
            
            if ( $apps ) {
                
                print LOG "Got authenticated apps\n";
                
                print LOG "Checkpoint 3\n";
                              
                available_apps_form( $cgi , $apps );

                close LOG;
                
                return;
                
            }

        }
        

    }

    sub available_apps_form {
        
        my $cgi  = shift;
        my $apps = shift;
        
        # Now. Let it be said right here and now, that I'm not proud with what's about to happen.
        # This is mostly a copy/paste of LoginForm/index.html ... with the combo box dynamically generated
        # from SQLite. Know how to do this nicely? I'm not a web guy. Bite me, and/or provide a patch ...
        
        my $first_half = qq {<!DOCTYPE html>
<html lang="en">
<head>
	<title>Login V2</title>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
<!--===============================================================================================-->	
	<link rel="icon" type="image/png" href="images/icons/favicon.ico"/>
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="vendor/bootstrap/css/bootstrap.min.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="fonts/font-awesome-4.7.0/css/font-awesome.min.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="fonts/iconic/css/material-design-iconic-font.min.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="vendor/animate/animate.css">
<!--===============================================================================================-->	
	<link rel="stylesheet" type="text/css" href="vendor/css-hamburgers/hamburgers.min.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="vendor/animsition/css/animsition.min.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="vendor/select2/select2.min.css">
<!--===============================================================================================-->	
	<link rel="stylesheet" type="text/css" href="vendor/daterangepicker/daterangepicker.css">
<!--===============================================================================================-->
	<link rel="stylesheet" type="text/css" href="css/util.css">
	<link rel="stylesheet" type="text/css" href="css/main.css">
<!--===============================================================================================-->
</head>
<body>
	
	<div class="limiter">
		<div class="container-login100">
			<div class="wrap-login100">
				<form class="login100-form validate-form" method="post">
					<span class="login100-form-title p-b-26">
						Select an app from the list of configured apps for this login:
					</span>

					<div class="wrap-input100">
						<select type="combo" name="app" placeholder="Select app...">};
    
        my $second_half = qq {                                                </select>
						<span class="focus-input100" data-placeholder="app"></span>
					</div>

					<div class="container-login100-form-btn">
						<div class="wrap-login100-form-btn">
							<div class="login100-form-bgbtn"></div>
							<button class="login100-form-btn">
								Launch
							</button>
						</div>
					</div>

				</form>
			</div>
		</div>
	</div>
	

	<div id="dropDownSelect1"></div>
	
<!--===============================================================================================-->
	<script src="vendor/jquery/jquery-3.2.1.min.js"></script>
<!--===============================================================================================-->
	<script src="vendor/animsition/js/animsition.min.js"></script>
<!--===============================================================================================-->
	<script src="vendor/bootstrap/js/popper.js"></script>
	<script src="vendor/bootstrap/js/bootstrap.min.js"></script>
<!--===============================================================================================-->
	<script src="vendor/select2/select2.min.js"></script>
<!--===============================================================================================-->
	<script src="vendor/daterangepicker/moment.min.js"></script>
	<script src="vendor/daterangepicker/daterangepicker.js"></script>
<!--===============================================================================================-->
	<script src="vendor/countdowntime/countdowntime.js"></script>
<!--===============================================================================================-->
	<script src="js/main.js"></script>

</body>
</html>};
        
        print_header( 'text/html' );
        
        print $first_half;
        foreach my $app ( @{$apps} ) {
            print "                <option>$app</option>\n";
        }
        print $second_half;
    }
    
}

my $pid = WebServer->new( $service_port )->run;
