# broadway_proxy
A session manager and transparent proxy for gtk/broadway applications

![alt text](https://tesla.duckdns.org/broadway_proxy.png)

## Pre-Installation

To install dependencies for CentOS 7.7:
`yum install perl-Gtk3 perl-XML-Simple perl-DBD-SQLite perl-HTTP-Server-Simple perl-File-Slurp`

Some dependencies are not available via yum:

`unsetenv LD_LIBRARY_PATH && perl -MCPAN -e 'install Gtk3::Ex::DBI::Form' && perl -MCPAN -e 'install Data::GUID'`


## Initial Configuration

Before running, you need to launch the management GUI, which will
create a configuration database. The management GUI is a perl/gtk
application. Run it:

> perl config.pl

Add some applications you want to expose to web users. To start
with, try adding 'gedit'.

Add a user and provide a password. The password will be hashed before
inserting into the DB.

Finally, enable some apps for users, by selecting an app, a user,
and clicking the 'add' button int the bottom-right corner.

## Launching services

There is a wrapper script to launch all the required services:

> ./launch_services.sh

## How it works

There are 3 services that are launched on startup, and one dynamically
launched:

### broadway_proxy.pl

This service is the front-end that your web browser will hit. At its heart
is a TCP proxy based on an asynchronous event loop,
by Peteris Krumins (peter@catonmat.net). Incoming requests are inspected
to locate our authentication cookie. The client is proxied to various
endpoints based on this cookie.

- If no cookie exists, the client is served the authentication page

- If a cookie exists, but no application has been selected, the client
is served a page that lists applications available to them

- If a cookie exists and an application has been selected, the client
is proxied to the broadway port that their application instance is
running on

### auth_service.pl

This service implements a login page. Successful logins generate an
authentication cookie, which contains a UUID. The UUID is stamped
in their record in our SQLite config database, along with a port
( which will be the port that the user_app_service is running on ).
Finally, a client refresh is triggered, which will send the client
back to the broadway proxy. The proxy should see the auth cookie, and
proxy the user_app_service for them.

### user_app_service.pl

This service lists available apps for a logged-in user. This could
use some visual 'improvements' :) When a user makes a selection,
it gets checked against the config DB ( to make sure they haven't
injected something they're not allowed to run ). If everything checks
out, a free port is located ( to run broadway on ) and an instance of
sessionmanager.pl is forked, and passed detail of the application to
launch and manage ( including the port to run broadway on ).
Finally, the user's record in the config DB is updated with the broadway
port, and another client refresh is triggered.

### sessionmanager.pl

This service launches both the application instance *and* broadwayd
instance for a logged-in user. It then waits for either process to
exit, and when one does, cleans up by killing the other to reclaim
the port.

## TODO

Apart from cleaning up the user_app_service.pl service, we could
use some https termination for enterprise security. This could be
done with an nginx proxy placed in front of broadway_proxy.pl. If
you're going to have clients connect from an insecure network, then
this is highly advised. Without https, your username/password/cookie
will be sent in plain text. For *my* use cases, what we have is already
good enough. Please feel free to contribute and https solution :)
