#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-Machine.t - Trog::Machine: fetching a directory, and not fetching it twice

=cut

# A -f in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use Test::More;
use Capture::Tiny qw{capture_stdout capture_stderr};
use Test::NoWarnings;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Path();
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin::libs;
use Provisioner::Vars();

use_ok('Trog::Machine') or BAIL_OUT('Trog::Machine does not load; the install is incomplete');

# A machine reached over the network, which none of these ever open a
# connection to: everything asserted on here is decided before rsync runs.
sub remote (%overrides) {
    return Trog::Machine->new(
        host     => 'hv.test',
        user     => 'someadmin',
        port     => 2222,
        key_path => '/bogus/domains/vm.test/key.rsa',
        %overrides,
    );
}

# The same object, but the machine is us.  rsync still runs; ssh does not.
sub here (@args) {
    my $machine = Trog::Machine->new(@args);
    my $mock    = Test::MockModule->new('Trog::Machine');
    $mock->redefine( is_local => sub { 1 } );
    return ( $machine, $mock );
}

# Runs get_dir on $machine against a File::Rsync that moves nothing and
# succeeds, and returns what rsync was built with, what it was asked to move,
# and what get_dir returned.
sub rsync_for ( $machine, @get_dir ) {
    my %got;
    my $mock = Test::MockModule->new('File::Rsync');
    $mock->redefine( new  => sub { my ( $class, %args ) = @_; $got{built} = \%args; return bless {}, $class } );
    $mock->redefine( exec => sub { my ( $self,  %args ) = @_; $got{moved} = \%args; return 1 } );
    $mock->redefine( out  => sub { return [] } );
    $got{returned} = $machine->get_dir(@get_dir);
    return \%got;
}

subtest 'a class keeps one object for the process, and forgets it' => sub {
    {

        package Trog::Machine::KeepsOne;
        use parent -norequire, 'Trog::Machine';

        package Trog::Machine::KeepsAnother;
        use parent -norequire, 'Trog::Machine';
    }
    my $one     = Trog::Machine::KeepsOne->new( name => 'one' );
    my $another = Trog::Machine::KeepsAnother->new( name => 'another' );

    is( Trog::Machine::KeepsOne->keep($one), $one, 'keep returns what it keeps' );
    Trog::Machine::KeepsAnother->keep($another);
    is( Trog::Machine::KeepsOne->kept(),     $one,     'and kept returns it' );
    is( Trog::Machine::KeepsAnother->kept(), $another, 'one for each class that keeps one' );

    is( Trog::Machine::KeepsOne->forget(),   1,        'forget returns 1' );
    is( Trog::Machine::KeepsOne->kept(),     undef,    'and the class keeps nothing then' );
    is( Trog::Machine::KeepsAnother->kept(), $another, 'while another class keeps its own' );
    Trog::Machine::KeepsAnother->forget();

    is( $one->name,               'one', 'a machine has the name that it was given' );
    is( Trog::Machine->new->name, undef, 'or none' );
};

subtest 'the ssh rsync is told to use' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $rsh = rsync_for( remote(), '/bogus/lib/deluged', "$dir/deluged" )->{built}{rsh};

    like( $rsh, qr{\A ssh \s -p \s 2222 \b},                  'the port, which rsync cannot get from anywhere else' );
    like( $rsh, qr{-i \s /bogus/domains/vm[.]test/key[.]rsa}, 'and the key, for the same reason' );

    # The same options Net::OpenSSH::More puts on its own master.  A guest
    # rebuilt an hour ago presents a host key nothing has seen before, and
    # refusing it would be this working exactly as intended and failing anyway.
    like( $rsh, qr{StrictHostKeyChecking=no},     'a host key nobody has seen is expected here' );
    like( $rsh, qr{UserKnownHostsFile=/dev/null}, 'and is not written down afterwards' );

    my $keyless = rsync_for( Trog::Machine->new( host => 'hv.test' ), '/bogus/lib/deluged', "$dir/deluged" );
    unlike( $keyless->{built}{rsh}, qr{-i}, 'no key, no -i naming a file that is not there' );
};

subtest 'every machine gets a connection of its own' => sub {

    # Net::OpenSSH::More caches connections by user, host and port, and hands
    # the cached one back without asking whether it still reaches anything.
    # Rebuilding a guest ran a command on the old one during the salvage and
    # then, in the same process, connected to the new one at the same address:
    # it got the old guest's connection, and the first command through it died
    # "Broken pipe".
    my %asked;
    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new => sub { my ( $class, %opts ) = @_; %asked = %opts; return bless {}, $class } );

    remote()->ssh;
    is( $asked{no_cache}, 1,         'the library is told not to share one' );
    is( $asked{host},     'hv.test', 'for the machine that was asked about' );
};

subtest 'the port the far side listens on' => sub {
    my $mock = Test::MockModule->new('Trog::Machine');
    my $asked;

    $mock->redefine(
        capture_cmd => sub {
            $asked = $_[1];
            return "2222\n";
        }
    );
    is( remote()->sshd_port, 2222, 'what its configuration says' );
    like( $asked, qr{sshd_config[.]d}, 'asked of the drop-in directory as well as the main file' );

    # No Port line is not a failure to find one: it is how every stock install
    # says 22.  Test::NoWarnings at the end of this file is the assertion that
    # nothing was said about it -- this used to warn, and now runs against
    # ourselves on every provision.
    $mock->redefine( capture_cmd => sub { return "\n" } );
    is( remote()->sshd_port, 22, 'and 22 when it says nothing' );
};

subtest 'what get_dir asks rsync for' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $got = rsync_for( remote(), '/bogus/lib/deluged', "$dir/deep/deluged", exclude => ['secrets.key'], update => 1, sudo => 1 );
    ok( $got->{returned}, 'it comes' );

    is( $got->{moved}{src},  'someadmin@hv.test:/bogus/lib/deluged/', 'the guest is the source' );
    is( $got->{moved}{dest}, "$dir/deep/deluged/",                    'and we are the destination' );
    is_deeply(
        [ @{ $got->{built} }{qw{exclude update rsync-path}} ],
        [ ['secrets.key'], 1, 'sudo -n rsync' ],
        'with what must not come down, what must not come back, and who to read it as'
    );

    # rsync makes the last component of a destination and nothing above it, and
    # a salvage is pointed two or three levels into a data directory that may
    # itself be new this run.
    ok( -d "$dir/deep/deluged", 'the path above the destination is ours to make' );
};

subtest 'a salvage never removes our copy of something the guest stopped having' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/src");
    File::Slurper::Temp::write_text( "$dir/src/state.db", "state\n" );

    my ( $machine, $mock ) = here();

    ok( $machine->get_dir( "$dir/src", "$dir/dst" ), 'the first fetch works' );
    ok( -f "$dir/dst/state.db",                      'and brings the state down' );

    # The guest stops producing it -- the service was reconfigured, or the file
    # was only ever there once.
    unlink("$dir/src/state.db") or die "could not remove the source: $!";

    $machine->get_dir( "$dir/src", "$dir/dst" );

    # Without a directory to put it in, rsync could delete it and must not.
    # This is the only copy, and nothing else keeps a history of it.
    ok( -f "$dir/dst/state.db", 'and a second fetch without deleted_to leaves behind what the guest no longer has' );
};

subtest 'with deleted_to, our copy mirrors the guest, and what the guest dropped is set aside' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path( "$dir/src/old", "$dir/src/lib" );
    File::Slurper::Temp::write_text( "$dir/src/state.db",       "state\n" );
    File::Slurper::Temp::write_text( "$dir/src/lib/Gone.pm",    "1;\n" );
    File::Slurper::Temp::write_text( "$dir/src/old/stale.html", "stale\n" );
    symlink( '../state.db', "$dir/src/lib/link" ) or die "could not make the link: $!";

    my ( $machine, $mock ) = here();
    my $aside = "$dir/aside/20261111T000000Z";
    ok( $machine->get_dir( "$dir/src", "$dir/dst", deleted_to => $aside ), 'the first fetch works' );

    # An update of the guest removed a module, a directory and a link, and
    # rewrote the database.  A file that only our copy has, and that the
    # exclude names, is not the guest's business.
    unlink( "$dir/src/lib/Gone.pm", "$dir/src/lib/link", "$dir/src/old/stale.html" ) or die "could not remove from the source: $!";
    rmdir("$dir/src/old")                                                            or die "could not remove $dir/src/old: $!";
    File::Slurper::Temp::write_text( "$dir/src/state.db",  "state, rewritten\n" );
    File::Slurper::Temp::write_text( "$dir/dst/kept.sock", "ours\n" );

    my ($said) = capture_stdout { $machine->get_dir( "$dir/src", "$dir/dst", deleted_to => $aside, exclude => ['*.sock'] ) };

    ok( !-e "$dir/dst/lib/Gone.pm", 'a file that the guest dropped leaves our copy' );
    ok( !-e "$dir/dst/old",         'and so does a directory that it dropped' );
    ok( !-l "$dir/dst/lib/link",    'and a link' );
    is( File::Slurper::read_text("$dir/dst/state.db"), "state, rewritten\n", 'a file that changed still comes down' );
    ok( -f "$dir/dst/kept.sock", 'and an excluded file of ours stays' );

    # The salvage is the only copy, so a delete keeps what it removes.
    is( File::Slurper::read_text("$aside/lib/Gone.pm"), "1;\n", 'the dropped file is set aside at its own path' );
    ok( -f "$aside/old/stale.html", 'and the file of the dropped directory' );
    is( readlink("$aside/lib/link"), '../state.db', 'and the link, as a link' );
    ok( !-e "$aside/state.db",  'a file that was only overwritten is not set aside' );
    ok( !-e "$aside/kept.sock", 'and neither is an excluded one' );
    like( $said, qr{Set[ ]aside[ ]3[ ]files}, 'and the fetch says how many it set aside' );
};

subtest 'a fetch that cannot list what the guest dropped sets nothing aside' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/dst");
    File::Slurper::Temp::write_text( "$dir/dst/state.db", "state\n" );

    my ( $machine, $mock ) = here();
    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @warnings, $_[0] ) };
        $machine->get_dir( "$dir/was-never-here", "$dir/dst", deleted_to => "$dir/aside" );
    };

    # A source that is not there makes the dry run fail, which is not the same
    # as a source that holds nothing.
    is( $ok, 0, 'the fetch fails' );
    ok( -f "$dir/dst/state.db", 'and our copy is whole' );
    ok( !-e "$dir/aside",       'and nothing was set aside' );
    like( $warnings[0], qr{could[ ]not[ ]list}, 'and it says that it could not list what to set aside' );
};

subtest 'a privileged fetch asks the far end to be root, and not to wait for a password' => sub {

    # A real destination, because get_dir makes the path above it before rsync
    # is reached -- see the subtest above.
    my $dir   = tempdir( CLEANUP => 1 );
    my %built = %{ rsync_for( remote(), '/bogus/lib/redis', "$dir/redis", sudo => 1 )->{built} };

    # A service keeps its state in a directory it owns and nobody else can open,
    # so an unprivileged rsync walks the tree, makes the local directories,
    # copies nothing out of them and exits happy -- which cannot be told from a
    # guest that has no state yet.
    is( $built{'rsync-path'}, 'sudo -n rsync', 'root at the far end' );

    # -n, because there is no terminal on the other end of this: a sudo that
    # decided to ask for a password would sit there until the timeout instead of
    # failing where somebody can see it.
    like( $built{'rsync-path'}, qr/\s-n\b/, 'and it fails rather than waiting when sudo would ask' );

    my $ordinary = rsync_for( remote(), '/bogus/lib/deluged', "$dir/deluged" );
    ok( !exists $ordinary->{built}{'rsync-path'}, 'an ordinary fetch stays unprivileged' );
};

subtest 'rsync moves what changed and nothing else' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/src/config");
    File::Slurper::Temp::write_text( "$dir/src/state.db",           "state\n" );
    File::Slurper::Temp::write_text( "$dir/src/config/secrets.key", "do not travel\n" );

    my ( $machine, $mock ) = here();

    ok( $machine->get_dir( "$dir/src", "$dir/dst", exclude => ['secrets.key'] ), 'the first fetch works' );
    ok( -f "$dir/dst/state.db",                                                  'and brings the state down' );
    ok( !-f "$dir/dst/config/secrets.key",                                       'and leaves behind what was told to stay' );

    # The whole reason any of this is rsync.  A re-provision of a domain whose
    # data has not changed should cost a directory walk, not the data.
    #
    # Captured at the file descriptor, which is what Capture::Tiny does, rather
    # than by localising the glob: File::Rsync captures the child through
    # IPC::Run3, which saves and restores the real STDOUT, and an in-memory
    # handle in its place is not something it can hand back.
    my ($said) = capture_stdout { $machine->get_dir( "$dir/src", "$dir/dst", exclude => ['secrets.key'] ) };

    like( $said, qr{Total [ ] transferred [ ] file [ ] size: \s* 0\b}, 'the second fetch moves nothing, and says so' );
};

subtest 'a transfer that fails says which one, and does not pretend' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my ( $machine, $mock ) = here();

    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @warnings, $_[0] ) };
        $machine->get_dir( "$dir/was-never-here", "$dir/dst" );
    };

    is( $ok, 0, 'it returns false rather than a count nobody checks' );
    like( $warnings[0], qr{was-never-here}, 'and names the transfer that failed' );
    like( $warnings[0], qr{rsync}i,         'as rsync, so the exit status below it means something' );
};

subtest 'a file read off a remote machine comes back whole' => sub {

    # Net::OpenSSH::capture returns one element per line in list context, and
    # unhang calls what it is given in list context and hands a scalar caller
    # the first element -- so read_text came back as line one of the file.
    # Measured against a 233-line authorized_keys: 608 bytes of 128667.
    #
    # A one-line file read perfectly, which is why nothing caught it: the
    # callers that existed were reading a hypervisor's config values.
    my $file = "alpha\nbeta\ngamma\n";

    my $ssh  = FakeSSH->new($file);
    my $mock = Test::MockModule->new('Trog::Machine');
    $mock->redefine( is_local => sub { 0 } );
    $mock->redefine( ssh      => sub { $ssh } );

    my $got = remote()->read_text('/bogus/authorized_keys');
    is( $got, $file, 'every line of it, with the trailing newline the file has' );

    # The call has to say so itself; unhang cannot know what its caller wanted.
    ok( $ssh->{scalar_context}, 'because capture was asked in scalar context' );
};

{
    # Net::OpenSSH's capture, in the one respect that matters here: a list of
    # lines or the whole thing, depending on what it was asked for.
    package FakeSSH;

    sub new { my ( $class, $content ) = @_; return bless { content => $content }, $class }

    sub capture {
        my ($self) = @_;
        $? = 0;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read_text reads it, and a fake that does not set it tests nothing.
        if (wantarray) {
            $self->{scalar_context} = 0;
            return map { "$_\n" } split( m/\n/, $self->{content} );
        }
        $self->{scalar_context} = 1;
        return $self->{content};
    }
}

# Runs $code with a remote machine whose root reads the files of %$files, a
# file with the content undef being one that root cannot read.  Each write
# fails with $writes_fail.  $code gets the machine and the list of what was
# written and run as root.
sub with_root_files ( $files, $writes_fail, $code ) {
    my @did;
    my $mock = Test::MockModule->new('Trog::Machine');
    $mock->redefine(
        capture_cmd => sub ( $self, $cmd ) {
            my ($path) = $cmd =~ m{\Asudo[ ]-n[ ]cat[ ]'([^']+)'[ ]2>/dev/null\z} or die "not expecting: $cmd\n";
            return $files->{$path};
        }
    );
    $mock->redefine(
        run_cmd => sub ( $self, @argv ) {
            "@argv[0..3]" eq 'sudo -n test -s' or die "not expecting: @argv\n";
            my $path = $argv[-1];
            return exists $files->{$path} && ( $files->{$path} // 'unreadable' ) ne q{} ? 0 : 1;
        }
    );
    $mock->redefine(
        write_text => sub ( $self, $path, $text, %opts ) {
            push @did, [ $path, $text, $opts{mode} ];
            return $opts{sudo} && !$writes_fail ? 1 : 0;
        }
    );
    $mock->redefine( run_sudo => sub ( $self, @argv ) { push @did, [@argv]; return $argv[0] eq 'false' ? 1 : 0 } );
    return $code->( remote(), \@did );
}

subtest 'root_text is what root reads, and holds_line asks it for a whole line' => sub {
    with_root_files(
        { '/bogus/conf' => "allow br0\ninclude /bogus/other\n" },
        0,
        sub ( $machine, $ ) {
            is( $machine->root_text('/bogus/conf'),    "allow br0\ninclude /bogus/other", 'the text, without its last newline' );
            is( $machine->root_text('/bogus/missing'), q{},                               'and an empty string for a file that is not there' );
            ok( $machine->holds_line( '/bogus/conf',  'allow br0' ), 'a line that is there' );
            ok( !$machine->holds_line( '/bogus/conf', 'allow br' ),  'and not a line that only starts one' );
        }
    );
};

subtest 'rewrite_lines keeps what keep keeps, and adds after it' => sub {
    with_root_files(
        { '/bogus/conf' => "one\ntwo\nthree\n" },
        0,
        sub ( $machine, $did ) {
            ok( $machine->rewrite_lines( '/bogus/conf', keep => sub ($line) { $line ne 'two' }, add => ['four'], mode => '0600' ), 'it returns true' );
            is_deeply( $did, [ [ '/bogus/conf', "one\nthree\nfour\n", '0600' ] ], 'the kept lines in their order, the new one after them, with the mode' );

            @$did = ();
            $machine->rewrite_lines( '/bogus/conf', add => ['four'] );
            is_deeply( $did, [ [ '/bogus/conf', "one\ntwo\nthree\nfour\n", '0644' ] ], 'without keep it keeps every line, and the mode is 0644' );

            @$did = ();
            $machine->rewrite_lines( '/bogus/new', add => ['first'] );
            is_deeply( $did, [ [ '/bogus/new', "first\n", '0644' ] ], 'a file that is not there yet gets the new lines' );
        }
    );
};

subtest 'rewrite_lines does not write from a read that failed' => sub {
    with_root_files(
        { '/bogus/conf' => undef },
        0,
        sub ( $machine, $did ) {
            like( exception { $machine->rewrite_lines( '/bogus/conf', add => ['mine'] ) }, qr{refusing[ ]to[ ]rewrite[ ]it[ ]blind}, 'it dies' );
            is_deeply( $did, [], 'and writes nothing' );
        }
    );
    with_root_files(
        { '/bogus/conf' => "x\n" },
        1,
        sub ( $machine, $ ) {
            like( exception { $machine->rewrite_lines( '/bogus/conf', add => ['y'] ) }, qr{Could[ ]not[ ]write[ ]/bogus/conf}, 'and it dies when the write fails' );
        }
    );
};

subtest 'run_sudo_or_die dies unless the command succeeds' => sub {
    with_root_files(
        {}, 0,
        sub ( $machine, $ ) {
            is( $machine->run_sudo_or_die(qw{true now}), 1, 'a command that exits 0' );
            like( exception { $machine->run_sudo_or_die(qw{false now}) }, qr/\ACould[ ]not[ ]run[ ]false[ ]now[ ]on[ ]/, 'one that does not dies, naming it' );
        }
    );
};

subtest 'list_dir takes a path with a space in it' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/two words/inside");

    my ( $machine, $mock ) = here();
    is_deeply( [ $machine->list_dir("$dir/two words") ], ['inside'], 'on this machine' );
    undef $mock;    ## no critic (ProhibitUselessVarClearing) -- restores the real is_local, so that remote() below is not taken for this machine

    # The command goes to a shell here rather than over ssh, which is what the
    # far side does with it too.
    my $remote = Test::MockModule->new('Trog::Machine');
    $remote->redefine( capture_cmd => sub { IPC::Run3::run3( $_[1], \undef, \my $out, \undef ); return $out } );
    is_deeply( [ remote()->list_dir("$dir/two words") ],         ['inside'], 'and on another' );
    is_deeply( [ remote()->list_dir("$dir/none; echo leaked") ], [],         'where a semicolon is part of the name, not the end of a command' );
};

subtest 'a file copied here with sudo gets the mode it was asked for' => sub {
    my ( $machine, $mock ) = here();
    my @sudo;
    $mock->redefine( run_sudo => sub { my ( $self, @argv ) = @_; push @sudo, \@argv; return 0 } );
    my $copy = Test::MockModule->new('File::Copy');
    $copy->redefine( copy => sub { return 0 } );

    ok( $machine->put_file( '/bogus/setup.sh', '/bogus/root/setup.sh', sudo => 1, mode => '0755' ), 'the copy works' );
    is_deeply( $sudo[-1], [qw{chmod 0755 /bogus/root/setup.sh}], 'and is given the mode asked for' );

    $machine->put_file( '/bogus/devices.map', '/bogus/root/devices.map', sudo => 1 );
    is_deeply( $sudo[-1], [qw{chmod 0644 /bogus/root/devices.map}], 'or 0644, whatever the umask of root' );
};

{
    # Net::OpenSSH's capture2 on a machine whose sudo refuses the first command
    # with $said on stderr, and runs every later one.
    package FakeSudo;

    sub new { my ( $class, $said ) = @_; return bless { said => $said, sent => 0 }, $class }

    sub capture2 {
        my ($self) = @_;
        ## no critic (Variables::RequireLocalizedPunctuationVars) -- run_sudo reads it afterwards, as it would from the real call
        if ( !$self->{sent}++ ) {
            $? = $Provisioner::Vars::STATUS_EXIT_1;
            return ( undef, $self->{said} );
        }
        $? = 0;
        return ( q{}, q{} );
    }
}

# What run_sudo made of $said, the first thing sudo said: whether it gave the
# exit code back, asked for a password, or said the last one was wrong and
# asked again.  A password was given before the run, so asking never prompts.
sub sudo_reads ($said) {
    Trog::Machine::forget_sudo_passwords();
    Trog::Credentials->forget();
    Trog::Credentials->remember( 'sudo', 'hunter2' );

    my $ssh  = FakeSudo->new($said);
    my $mock = Test::MockModule->new('Trog::Machine');
    $mock->redefine( ssh => sub { $ssh } );

    my ( $stderr, $rc ) = capture_stderr { remote()->run_sudo(qw{true}) };
    Trog::Credentials->forget();

    my $sorry = $stderr =~ m/Sorry,[ ]try[ ]again/;
    return 'given back'  if $rc == 1 && $ssh->{sent} == 1 && !$sorry;
    return 'asked'       if $rc == 0 && $ssh->{sent} == 2 && !$sorry;
    return 'asked again' if $rc == 0 && $ssh->{sent} == 2 && $sorry;
    return "something else: exit $rc after $ssh->{sent} commands, saying '$stderr'";
}

subtest 'a remote command runs with no pager' => sub {

    # The far side, played here: one argument goes to a shell, and a list runs
    # as it is, as Net::OpenSSH::More sends them.
    my $far = Test::MockModule->new( 'Trog::Machine::FarSide', no_auto => 1 );
    $far->define(
        cmd => sub ( $, @command ) {
            IPC::Run3::run3( @command == 1 ? [ 'sh', '-c', $command[0] ] : \@command, \undef, \my $out, \undef );
            return ( $out, q{}, $? >> 8 );
        }
    );
    $far->define( cmd_exit_code => sub ( $self, @command ) { return ( $self->cmd(@command) )[2] } );
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( ssh => sub { return bless {}, 'Trog::Machine::FarSide' } );

    local @ENV{qw{SYSTEMD_PAGER PAGER}} = qw{less less};
    is( remote()->capture_cmd(q{echo "$SYSTEMD_PAGER $PAGER" | cat}),                 "cat cat\n", 'a shell string, a pipeline too, sees no pager' );
    is( remote()->run_cmd( 'sh', '-c', q{test "$SYSTEMD_PAGER $PAGER" = "cat cat"} ), 0,           'and so does a list' );
    is( remote()->run_cmd(q{test "$SYSTEMD_PAGER $PAGER" = "cat cat"}),               0,           'and a single string to run_cmd' );
    is( remote()->capture_cmd(q{timeout 5 echo ok}),                                  "ok\n",      'and the command still runs as it was written' );
};

subtest 'what sudo says when it wants a password it cannot ask for' => sub {
    is( sudo_reads("sudo: a password is required\n"),                                                'asked', 'sudo -n with no passwordless sudo' );
    is( sudo_reads("sudo: password is required\n"),                                                  'asked', 'and without the article' );
    is( sudo_reads("sudo: a terminal is required to read the password; either use the -S option\n"), 'asked', 'no terminal to read one at' );
    is( sudo_reads("sudo: no password was provided\n"),                                              'asked', 'and -S given nothing' );

    is( sudo_reads("a password is required\n"), 'given back', 'and nothing sudo did not say' );
    is( sudo_reads(q{}),                        'given back', 'nothing said is nothing wanted' );
    is( sudo_reads(undef),                      'given back', 'and neither is nothing captured' );
};

subtest 'what sudo says when the password it was given is wrong' => sub {
    is( sudo_reads("sudo: 1 incorrect password attempt\n"),  'asked again', 'one bad attempt, as sudo counts them' );
    is( sudo_reads("sudo: 3 incorrect password attempts\n"), 'asked again', 'and several' );
    is( sudo_reads("Sorry, try again.\n"),                   'asked again', 'the line it prints between attempts' );

    is( sudo_reads("sudo: a password is required\n"),     'asked',      'wanting a password is not having been given a wrong one' );
    is( sudo_reads("sudo: incorrect password attempt\n"), 'given back', 'nor is a count that is not there' );
};

# The file is usually authorized_keys, where one wrong write locks its owner
# out, so each way out is checked for what it leaves on disk.
Test::NoWarnings::had_no_warnings();
done_testing();
