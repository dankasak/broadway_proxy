#!/usr/bin/perl -w

use strict;
use warnings;

use Cwd;
use DBI;

use Gtk3 -init;

use constant    PERL_ZERO_RECORDS_INSERTED      => '0E0';

use Data::Dumper;

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

# Create our 'simple_config' table if it doesn't exist - this is required for our upgrade logic
$dbh->do(
    "create table if not exists simple_config (\n"
  . "    key    text       primary key\n"
  . "  , value  text\n"
  . ")"
) || die( $dbh->errstr );

sub do_upgrades {
    # $options will contain:
    # {
    #     current_version => $some_version_integer
    #   , upgrade_path    => $some_path_that_contains_schema_upgrades
    # }
    #
    # This sub performs upgrades to our database schema by parsing filenames in a given directory
    # ( filenames must contain a sequence number ). We've been passed our current version ( above ).
    # Any files with a sequence higher than our current version number are executed, in order, and we
    # then update the current version ( which is stored in simple_config ).
    my $options = shift;
    {
        no warnings 'uninitialized';
        print "Checking for upgrades ... current schema version: [" . $options->{current_version} . "]\n";
    }
    my $upgrade_hash = {};
    if ( ! -d $options->{upgrade_path} ) {
        return;
    }
    opendir( DIR, $options->{upgrade_path} ) || warn( $! );
    while ( my $file = readdir(DIR) ) {
        if ( $file =~ /(\d*)_([\w-]*)\.(dml|ddl)$/i ) {
            my ( $sequence, $name, $extension ) = ( $1, $2 );
            $upgrade_hash->{$sequence} = $file;
        }
    }
    close DIR;
    foreach my $sequence ( sort { $a <=> $b } keys %{$upgrade_hash} ) {
        if ( ! defined $options->{current_version} || $sequence > $options->{current_version} ) {
            my $this_file = $options->{upgrade_path} . "/" . $upgrade_hash->{$sequence};
            local $/;
            my $this_fh;
            open ( $this_fh, "<$this_file" )
                || die( $! );
            my $contents = <$this_fh>;
            close $this_fh;
            print "Executing schema upgrade: [" . $upgrade_hash->{$sequence} . "]\n";
            $dbh->do( $contents )
                || die( "Error upgrading schema:\n" . $dbh->errstr );
            # Bump the schema version. Unfortunately we don't have upsert syntax yet ( v3.22.0 vs v3.28.0 )
            my $records = $dbh->do( qq{ update simple_config set value = ? where key = 'version' }
              , {}
              , ( $sequence )
            ) || die( $dbh->errstr );
            if ( $records eq PERL_ZERO_RECORDS_INSERTED ) {
                $dbh->do( qq{ insert into simple_config ( key , value ) values ( 'version' , ? ) }
                  , {}
                  , ( $sequence )
                ) || die( $dbh->errstr );
            }
        }
    }
}

# Get our version and upgrade path, and trigger schema upgrades
my $current_dir = cwd();
my $upgrade_path = $current_dir . "/schema_upgrades";
my $sth = $dbh->prepare( "select value from simple_config where key = 'version'" ) || die( $dbh->errstr );
$sth->execute() || die( $sth->errstr );
my $row = $sth->fetchrow_hashref();
my $current_version = $row->{value};
do_upgrades(
    {
        current_version => $current_version
      , upgrade_path    => $upgrade_path
    }
);

# We're ready to launch the config GUI ...
print "Launching GUI ...\n";
my $window = ConfigWindow->new(
    {
        dbh         => $dbh
      , config_dir  => $config_dir
      , current_dir => $current_dir
    }
);

Gtk3->main();

##########################################

package ConfigWindow;

use warnings;
use strict;

use Gtk3::Ex::DBI::Form;
use Gtk3::Ex::DBI::Datasheet;
use Digest::MD5 qw(md5_hex);

use Glib qw/TRUE FALSE/;

sub new {
    
    my ( $class , $options ) = @_;
    
    my $self = {};
    
    $self->{options} = $options;
    
    bless $self, $class;
    
    $self->{builder} = Gtk3::Builder->new;
    
    $self->{builder}->add_objects_from_file(
        $self->{options}->{current_dir} . "/config.glade"
      , "config"
    );
    
    $self->{builder}->get_object( 'config' )->maximize();
    
    $self->{builder}->connect_signals( undef, $self );
    
    $self->{apps} = Gtk3::Ex::DBI::Datasheet->new(
      {
          dbh                   => $options->{dbh}
        , sql                   => {
                                       select      => "*"
                                     , from        => "apps"
                                   }
        , auto_incrementing     => FALSE
        , vbox                  => $self->{builder}->get_object( 'apps_box' )
        , auto_tools_box        => TRUE
      }
    );
    
    $self->{users} = Gtk3::Ex::DBI::Datasheet->new(
      {
          dbh                   => $options->{dbh}
        , sql                   => {
                                       select      => "*"
                                     , from        => "users"
                                   }
        , auto_incrementing     => FALSE
        , vbox                  => $self->{builder}->get_object( 'users_box' )
        , auto_tools_box        => TRUE
        , before_apply          => sub { $self->before_users_apply( @_ ) }
        , on_row_select         => sub{ $self->on_user_select( @_ ) }
      }
    );

    $self->{user_apps} = Gtk3::Ex::DBI::Datasheet->new(
      {
          dbh                   => $options->{dbh}
        , sql                   => {
                                       select      => "app_name"
                                     , from        => "user_apps"
                                     , where       => "username = ?"
                                     , bind_values => [ undef ]
                                   }
        , read_only             => TRUE
        , vbox                  => $self->{builder}->get_object( 'user_apps_box' )
        , auto_tools_box        => TRUE
        , recordset_tool_items  => [ qw ' add_app del_app ' ]
        , recordset_extra_tools => {
                                        add_app => {
                                                        type        => 'button'
                                                      , markup      => "<span color='darkgreen'>Add</span>"
                                                      , icon_name   => 'gtk-go-forward'
                                                      , coderef     => sub { $self->on_add_app_to_user( @_ ) }
                                                   }
                                      , del_app => {
                                                        type        => 'button'
                                                      , markup      => "<span color='red'>Remove</span>"
                                                      , icon_name   => 'gtk-go-back'
                                                      , coderef     => sub { $self->on_del_app_from_user( @_ ) }
                                                   }
                                   }
      }
    );
    
    $self->{simple_config} = Gtk3::Ex::DBI::Datasheet->new(
      {
          dbh                   => $options->{dbh}
        , sql                   => {
                                       select      => "*"
                                     , from        => "simple_config"
                                   }
        , auto_incrementing     => FALSE
        , vbox                  => $self->{builder}->get_object( 'simple_config_box' )
        , auto_tools_box        => TRUE
      }
    );
    
    return $self;
    
}

sub before_users_apply {

    my ( $self , $apply_info ) = @_;

    # Here we md5-hash the password ...
    $apply_info->{model}->set(
        $apply_info->{iter}
      , $self->{users}->column_from_column_name( "password" )
      , md5_hex(
            $apply_info->{model}->get( $apply_info->{iter} , $self->{users}->column_from_column_name( "password" ) )
        )
    );

    return TRUE;

}

sub on_user_select {

    my $self = shift;

    $self->{user_apps}->query(
        {
            where       => "username = ?"
          , bind_values => [ $self->{users}->get_column_value( "username" ) ]
        }
    );

}

sub on_add_app_to_user {

    my $self = shift;

    my $app_name = $self->{apps}->get_column_value( "app_name" );

    if ( ! $app_name ) {
        $self->dialog(
            {
                title => "No app selected"
              , type  => "error"
              , text  => "You need to select an app first ..."
            }
        );
        return TRUE;
    }

    my $username = $self->{users}->get_column_value( "username" );

    if ( ! $username ) {
        $self->dialog(
            {
                title => "No user selected"
              , type  => "error"
              , text  => "You need to select a user first ..."
            }
        );
        return TRUE;
    }

    eval {
        $self->{options}->{dbh}->do( "insert into user_apps ( username , app_name ) values ( ? , ? )" , {} , ( $username , $app_name ) )
            || die( $self->{options}->{dbh}->errstr );
    };

    my $err = $@;

    if ( $err ) {
        $self->dialog(
            {
                title => "Couldn't do it"
              , type  => "error"
              , text  => $err
            }
        );
        return TRUE;
    }

    $self->{user_apps}->query();

}

sub on_del_app_from_user {

    my $self = shift;

    my $app_name = $self->{user_apps}->get_column_value( "app_name" );

    if ( ! $app_name ) {
        $self->dialog(
            {
                title => "No app selected"
              , type  => "error"
              , text  => "You need to select an app first ..."
            }
        );
        return TRUE;
    }

    my $username = $self->{users}->get_column_value( "username" );

    if ( ! $username ) {
        $self->dialog(
            {
                title => "No user selected"
              , type  => "error"
              , text  => "You need to select a user first ..."
            }
        );
        return TRUE;
    }

    eval {
        $self->{options}->{dbh}->do( "delete from user_apps where username = ? and app_name = ?" , {} , ( $username , $app_name ) )
            || die( $self->{options}->{dbh}->errstr );
    };

    my $err = $@;

    if ( $err ) {
        $self->dialog(
            {
                title => "Couldn't do it"
              , type  => "error"
              , text  => $err
            }
        );
        return TRUE;
    }

    $self->{user_apps}->query();

}

sub on_config_destroy {

    my $self = shift;

    Gtk3::main_quit();

}

sub dialog {

    my ( $self, $options ) = @_;

    # This is a copy/paste from another project. We don't need most of it, but it also doesn't hurt to have it here.
    # Some things have been short-circuited to avoid bringing in other code.

    # TODO: port to Gtk3::Dialog as Gtk3 developers are
    #       getting cranky about the use of images

    my $buttons = 'GTK_BUTTONS_OK';

    if ( $options->{type} eq 'options' || $options->{type} eq 'input' ) {
        $buttons = 'GTK_BUTTONS_OK_CANCEL';
    } elsif ( $options->{type} eq 'question' ) {
        $buttons = 'GTK_BUTTONS_YES_NO';
    }

    my $parent_window;

    if ( $options->{parent_window} ) {
        $parent_window = $options->{parent_window};
    } elsif ( $self ) {
        # $parent_window = $self->get_window;
        $parent_window = $self->{builder}->get_object( 'config' );
    }

    my $gtk_dialog_type;

    if (  $options->{type} eq 'options' || $options->{type} eq 'input' ) {
        $gtk_dialog_type = 'question';
    } elsif ( $options->{type} eq 'textview' ) {
        $gtk_dialog_type = 'other';
    } else {
        $gtk_dialog_type = $options->{type};
    }

    my $dialog = Gtk3::MessageDialog->new(
        $parent_window
      , [ qw/modal destroy-with-parent/ ]
      , $gtk_dialog_type
      , $buttons
    );

    if ( $options->{title} ) {
        $dialog->set_title( $options->{title} );
    }

    if ( $options->{type} ne 'textview' && $options->{text} ) {
        # $dialog->set_markup( window::escape( undef, $options->{text} ) );
        $dialog->set_markup( $options->{text} );
    } elsif ( $options->{type} ne 'textview' && $options->{markup} ) {
        $dialog->set_markup( $options->{markup} );
    }

    my ( @radio_buttons, $entry, $sw, $textview );

    if ( $options->{type} eq 'options' ) {

        my $message_area = $dialog->get_message_area;

        my ( $box , $sw );

        if ( $options->{orientation} eq 'vertical' ) {
            $box = Gtk3::Box->new( 'GTK_ORIENTATION_VERTICAL', 0 );
            $sw = Gtk3::ScrolledWindow->new();
            $sw->set_size_request( 600, 300 ); # can't see anything unless we do this
        } else {
            $box = Gtk3::Box->new( 'GTK_ORIENTATION_HORIZONTAL', 0 );
        }

        foreach my $option ( @{$options->{options}} ) {

            my $radio_button = Gtk3::RadioButton->new_with_label_from_widget( $radio_buttons[0], $option );
            push @radio_buttons, $radio_button;
            $box->pack_end( $radio_button, TRUE, TRUE, 0);

        }

        if ( $sw ) {
            $sw->add( $box );
            $message_area->pack_end( $sw, TRUE, TRUE, 0 );
        } else {
            $message_area->pack_end( $box, TRUE, TRUE, 0 );
        }

    } elsif ( $options->{type} eq 'input' ) {

        my $message_area = $dialog->get_message_area;

        $entry = Gtk3::Entry->new;

        if ( exists $options->{default} ) {
            $entry->set_text( $options->{default} );
        }

        $message_area->pack_end( $entry, TRUE, TRUE, 0 );

    } elsif ( $options->{type} eq 'textview' ) {

        my $message_area = $dialog->get_message_area;

        $sw          = Gtk3::ScrolledWindow->new();
        $textview    = Gtk3::TextView->new();

        $sw->set_size_request( 1024, 768 ); # can't see anything unless we do this
        $sw->add( $textview );

        $message_area->pack_end( $sw, TRUE, TRUE, 0 );

        $textview->get_buffer->set_text( $options->{text} );

    }

    $dialog->show_all;

    my $response = $dialog->run;

    if ( $response eq 'cancel' ) {
        $dialog->destroy;
        return undef;
    }

    if ( $options->{type} eq 'options' ) {
        foreach my $radio_button ( @radio_buttons ) {
            if ( $radio_button->get_active ) {
                $response = $radio_button->get_label;
                last;
            }
        }
    } elsif ( $options->{type} eq 'input' ) {
        $response = $entry->get_text;
    }

    $dialog->destroy;

    return $response;

}

1;
