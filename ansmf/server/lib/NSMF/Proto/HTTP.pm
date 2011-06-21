package NSMF::Proto::HTTP;

use v5.10;
use strict;

use NSMF;
use NSMF::Common::Util;
use NSMF::ModMngr;
use NSMF::AuthMngr;
use NSMF::ConfigMngr;

use POE;
use POE::Session;
use POE::Wheel::Run;
use POE::Filter::Reference;

use Date::Format;
use Data::Dumper;
use Compress::Zlib;
use MIME::Base64;
our $VERSION = '0.1';

my $instance;
my $config = NSMF::ConfigMngr->instance;
my $modules = $config->{modules} // [];


my $ACCEPTED = 'NSMF/1.0 200 OK ACCEPTED';

sub instance {
    unless ($instance) {
        my ($class) = @_;
        return bless({}, $class);
    }

    return $instance;
}

sub states {
    my ($self) = @_;

    return unless ref($self) eq 'NSMF::Proto::HTTP';

    return [
        'dispatcher',
        'authenticate',
        'identify',
        'got_ping',
        'got_pong',
        'got_post',
        'send_ping',
        'send_pong',
        'send_error',
        'get',
        'child_output',
        'child_error',
        'child_signal',
        'child_close',
    ];
}

sub dispatcher {
    my ($kernel, $request) = @_[KERNEL, ARG0];

    my $AUTH_REQUEST = '^AUTH (\w+) (\w+) NSMF\/1.0$';
    my $ID_REQUEST   = '^ID (\w)+ NSMF\/1.0$';
    my $PING_REQUEST = 'PING (\d)+ NSMF/1.0';
    my $PONG_REQUEST = 'PONG (\d)+ NSMF/1.0';
    my $POST_REQUEST = '^POST (\w)+ (\d)+ NSMF\/1.0'."\n\n".'(\w)+';
    my $GET_REQUEST  = '^GET (\w)+ NSMF\/1.0$';

    my $action;

    given($request) {
        when(/$AUTH_REQUEST/i) { $action = 'authenticate' }
        when(/$ID_REQUEST/i)   { $action = 'identify' }
        when(/^$PING_REQUEST/i) { $action = 'got_ping' }
        when(/^$PONG_REQUEST/i) { $action = 'got_pong' }
        when(/$POST_REQUEST/i) { $action = 'got_post' }
        when(/$GET_REQUEST/i)  { $action = 'get' }
        default: {
            say Dumper $request;
            $action = 'send_error';
        }
    }
    $kernel->yield($action, $request);
}

sub authenticate {
    my ($kernel, $session, $heap, $input) = @_[KERNEL, SESSION, HEAP, ARG0];
    $input = trim($input);

    say  "  -> Authentication Request: " . $input if $NSMF::DEBUG;

    my $parsed = parse_request(auth => $input);
    unless (ref $parsed eq 'AUTH') {
    say 'authhh';
        $heap->put('NSMF/1.0 400 BAD REQUEST');
        return;
    }

    my $agent    = lc $parsed->{agent};
    my $key      = lc $parsed->{key};

    eval {
        NSMF::AuthMngr->authenticate($agent, $key);
    };

    if ($@) {
        say '    = Not Found ' .$@ if $NSMF::DEBUG;
        $heap->{client}->put("NSMF/1.0 402 UNSUPPORTED\r\n");
        return;
    }

    $heap->{agent}    = $agent;
    say "    [+] Agent authenticated: $agent" if $NSMF::DEBUG;
    $heap->{client}->put("NSMF/1.0 200 OK ACCEPTED\r\n");
}

sub identify {
    my ($kernel, $session, $heap, $request) = @_[KERNEL, SESSION, HEAP, ARG0];

    my @data   = split /\s+/, trim($request);
    my $module = trim lc $data[1];
    my $netgroup = trim lc $data[2];


    if ($heap->{session_id}) {
        say  "$module is already authenticated" if $NSMF::DEBUG;
        return;
    }

    if ($module ~~ @$modules) {

        say "    ->  " .uc($module). " supported!" if $NSMF::DEBUG;

        $heap->{module_name} = $module;
        $heap->{session_id} = 1;
        $heap->{status}     = 'EST';

        eval {
            $heap->{module} = NSMF::ModMngr->load(uc $module);
        };

        if ($@) {
            say "    [FAILED] Could not load module: $module";
            say $@ if $NSMF::DEBUG;
        }
   
        $heap->{session_id} = $_[SESSION]->ID;

        if (defined $heap->{module}) {
            # say "Session Id: " .$heap->{session_id};
            # say "Calilng Hello World Again in the already defined module";
            say "      ----> Module Call <----"; 
            $heap->{client}->put("NSMF/1.0 200 OK ACCEPTED\r\n");
            return;
            my $child = POE::Wheel::Run->new(
                Program => sub { $heap->{module}->run  },
                StdoutFilter => POE::Filter::Reference->new(),
                StdoutEvent => "child_output",
                StderrEvent => "child_error",
                CloseEvent  => "child_close",
            );

            $_[KERNEL]->sig_child($child->PID, "child_signal");
            $_[HEAP]{children_by_wid}{$child->ID} = $child;
            $_[HEAP]{children_by_pid}{$child->PID} = $child;
        }
    } 
    else {
        $heap->{client}->put("NSMF/1.0 401 UNSUPPORTED\r\n");
    }

}

sub got_pong {
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

    say "  <- Got PONG" if $NSMF::DEBUG;
}

sub got_ping {
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

    my @params    = split /\s+/, trim($input);
    my $ping_time = $params[1]; 

    $heap->{ping_recv} = $ping_time if $ping_time;

    unless ($heap->{status} eq 'EST' and $heap->{session_id}) {
        $heap->{client}->put("NSMF/1.0 401 UNAUTHORIZED\r\n");
        return;
    }

    say "  <- Got PING" if $NSMF::DEBUG;
    $kernel->yield('send_pong');
}

sub child_output {
    my ($kernel, $heap, $output) = @_[KERNEL, HEAP, ARG0];
    say Dumper $output;
}

sub child_error {
    say "Child Error: $_[ARG0]";
}

sub child_signal {
    #say "   * PID: $_[ARG1] exited with status $_[ARG2]";
    my $child = delete $_[HEAP]{children_by_pid}{$_[ARG1]};

    return unless defined $child;

    delete $_[HEAP]{children_by_wid}{$child->ID};
}

sub child_close {
    my $wid = $_[ARG0];
    my $child = delete $_[HEAP]{children_by_wid}{$wid};

    unless (defined $child) {
    #    say "Wheel Id: $wid closed";
        return;
    }

    #say "   * PID: " .$child->PID. " closed";
    delete $_[HEAP]{children_by_pid}{$child->PID};
}

sub got_post {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    unless ($heap->{status} eq 'EST' and $heap->{session_id}) {
        $heap->{client}->put("NSMF/1.0 400 BAD REQUEST\r\n");
        return;
    }

    my $parsed = parse_request(post => $request);

    return unless ref $parsed eq 'POST';

    say ' -> This is a post for ' . $heap->{module_name};
    say '    - Type: '. $parsed->{type};
    say '    - Job Id: ' .$parsed->{job_id};

    my $append;
    my $data = $parsed->{data};
    for my $line (@{ $parsed->{data} }) {
        $append .= $line;
    }

    my @sessions = split /\n/, decode_base64 $append;
    
    my $module = $heap->{module};
    for my $session ( @sessions ) {
        next unless $module->validate( $session );

        $module->save( $session ) or say $module->errstr;
        say "    Session saved";
    }
    
}   

sub send_ping {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    say '  -> Sending PING';
    my $payload = "PING " .time. " NSMF/1.0\r\n";
    $heap->{client}->put($payload);
}

sub send_pong {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    say '  -> Sending PONG';
    my $payload = "PONG " .time. " NSMF/1.0\r\n";
    $heap->{client}->put($payload);
}

sub send_error {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $client = $heap->{client};
    warn "[!] BAD REQUEST" if $NSMF::DEBUG;

        say "Sending BAD error";
    $client->put("NSMF/1.0 400 BAD REQUEST\r\n");
}

sub get {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    unless ($heap->{status} eq 'EST' and $heap->{session_id}) {
        say "Sending BAD GET";
        $heap->{client}->put("NSMF/1.0 400 BAD REQUEST\r\n");
        return;
    }

    my $req = parse_request(get => $request);
    unless (ref $req) { 
    say 'BAD in GET';
        $heap->{client}->put('NSMF/1.0 400 BAD REQUEST');
        return;
    }

    # search data
    my $payload = encode_base64( compress( 'A'x1000 ) );
    $heap->{client}->put('POST ANumbers NSMF/1.0' ."\r\n". $payload);
    
}

1;