package NSMF::Node;

use strict;
use v5.10;
use POSIX;
use Carp qw(croak);
use NSMF::Error;
use NSMF::Net;
use NSMF::Comm qw(init);
use NSMF::Auth;
use NSMF::Config;
use NSMF::Util;
use base qw(NSMF::Action NSMF::Proto);
use Data::Dumper;
use POE;
our $VERSION = '0.1';

sub id {
    my ($self, $arg) = @_;
    $self->{id} = $arg if defined_args($arg);
    return $self->{id};
}
sub nodename {
    my ($self, $arg) = @_;
    $self->{nodename} = $arg if defined_args($arg);
    return $self->{nodename};
}
sub netgroup {
    my ($self, $arg) = @_;
    $self->{netgroup} = $arg if defined_args($arg);
    return $self->{netgroup};
}
sub server {
    my ($self, $arg) = @_;
    $self->{server} = $arg if defined_args($arg);
    return $self->{server};
}
sub port {
    my ($self, $arg) = @_;
    $self->{port} = $arg if defined_args($arg);
    return $self->{port};
}
sub secret {
    my ($self, $arg) = @_;
    $self->{secret} = $arg if defined_args($arg);
    return $self->{secret};
}
# Constructor
sub new {
    my $class = shift;

    bless {
        id          => undef,
    	nodename    => undef,
    	netgroup    => undef,
    	server      => undef,
        port        => undef,
    	secret      => undef,
        config_path => undef,
    	__handlers => {
	    	_net     => undef,
    		_db      => undef,
            _sessid  => undef,
    	},
        __settings => undef,
    }, $class;
}

# Public Interface to load config as pair of names and values
sub load_config {
    my ($self, $path) = @_;

    return unless ref($self) ~~ /NSMF::Node/;
#    return unless $path ~~ /[a-zA-Z0-9-\.]+/;

    my $config = NSMF::Config::load($path);

    $self->{config_path} =  $path;
    $self->{name}        =  ref($self)          // 'NSMF::Node';
    $self->{id}          =  $config->{id}       // '';
    $self->{nodename}    =  $config->{nodename} // '';
    $self->{netgroup}    =  $config->{netgroup} // '';
    $self->{server}      =  $config->{server}   // '0.0.0.0';
    $self->{port}        =  $config->{port}     // '10101';
    $self->{secret}      =  $config->{secret}   // '';
    $self->{__settings}  =  $config->{settings} // {};

    return $config;
}

# Returns actual configuration settings
sub config {
    my ($self) = @_;

    return unless ref($self) ~~ /NSMF::Node/;
    
    return {
        id       => $self->id,
        nodename => $self->nodename,
        server   => $self->server,
        port     => $self->port,
        netgroup => $self->netgroup,
        secret   => $self->secret,
    };

}

# Connect method
sub connect {
   my ($self) = @_;

#   print_error "Server or " unless defined_args($self->server, $self->port);
   return if defined $self->{__handlers}->{_net};

   my $conn = NSMF::Net::connect($self->server, $self->port);  
   $self->{__handlers}->{_net} = $conn;

   return $self->{__handlers}->{_net};   
}

sub connect_ng {
   my ($self) = @_;

   return unless  defined_args($self->server, $self->port);
   NSMF::Comm::init( $self );  
}

# Returns the actual session
sub session {
    my ($self) = @_;

    return unless ref($self) ~~ /NSMF::Node/;
    return $self->{__handlers}->{_sessid};
}

# Authentication method
# Returns the session id or 0 if authentication fails. 
sub authenticate2 {
    my ($self) = @_;

    return unless ref($self) ~~ /NSMF::Node/;
    my $session = qq//;

    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 10;
        $session = NSMF::Auth::send_auth(
                       $self->{__handlers}->{_net}, 
                       { 
                           id       => $self->id, 
                           server   => $self->server, 
                           secret   => $self->secret, 
                           nodename => $self->nodename, 
                           netgroup => $self->netgroup, 
                       }
                   );
	    alarm 0;
    };

    alarm 0;

    if ($@) {
	    croak("[!! Error!") unless $@ eq "alarm\n";   # propagate unexpected errors
        print_error "Connection Timeout";exit;
    } 
    else {
        $self->{__handlers}->{_sessid} = $session;
        print_error "Authentication Failed." if $session ~~ 0;

    	return $self->{__handlers}->{_sessid};
    }
}

# Synchronization method.
# Uses $self->connect and $self->authenticate.
# Returns the session.
sub sync {
    my ($self) = @_;

    return 0 unless ref($self) ~~ /NSMF::Node/;

    if ( $self->connect() ) {
        return $self->authenticate2();
    }
    
    return;
}

sub put {
    my ($self, $data) = @_;

    return unless defined $data;
    my $SS     = $self->{__handlers}->{_net} // print_error('Could not send data. No socket created');
    my $DEBUG = NSMF::DEBUG;
    my $line = qq();
    my $HEADER = "POST DATA";

    $SS->say($HEADER);
    $SS->flush();
    say "Sent HEADER: '$HEADER'." if $DEBUG;
    $line = qq();
    sysread($SS, $line, 8192, length $line);
    chomp $line;
    $line =~ s/\r//;
    if ( $line =~ /200 OK ACCEPTED/ ) {
        print $SS "$data\n.\r\n";
        $SS->flush();
        print_status "Data sent." if $DEBUG;
        $line = qq();
        sysread($SS, $line, 8192, length $line);
        chomp $line;
        $line =~ s/\r//;
        if ( $line =~ /200 OK ACCEPTED/ ) {
            print_status "Server recived data OK." if $DEBUG;
            return 0; #OK
        } else {
            print_status "Server " . $self->server . " sent bogus response to \"EOF\": '$line'." if $DEBUG;
        }
    } else {
        print_status "Server " . $self->server . " sent bogus response to \"POST DATA\": '$line'." if $DEBUG;
    }
    return 1; #ERROR
}


1;
