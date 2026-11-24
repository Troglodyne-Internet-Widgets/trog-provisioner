#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

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
        capture_quiet => sub {
            shift;
            $asked = join( q{ }, @_ );
            return "Port 22\nPort 2222\n";
        }
    );
    is( remote()->sshd_port, 2222, 'the last Port line of its configuration' );
    like( $asked, qr{sshd_config[.]d}, 'asked of the drop-in directory as well as the main file' );

    # No Port line is not a failure to find one: it is how every stock install
    # says 22.  Test::NoWarnings at the end of this file is the assertion that
    # nothing was said about it -- this used to warn, and now runs against
    # ourselves on every provision.
    $mock->redefine( capture_quiet => sub { return "\n" } );
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
        capture_cmd => sub ( $self, @argv ) {
            my $path = $argv[-1];
            join( q{ }, @argv[ 0 .. 3 ] ) eq 'sudo -n sh -c' or die "not expecting: @argv\n";
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
    $remote->redefine( capture_quiet => sub { my ( undef, @argv ) = @_; IPC::Run3::run3( \@argv, \undef, \my $out, \undef ); return $out } );
    is_deeply( [ remote()->list_dir("$dir/two words") ],         ['inside'], 'and on another' );
    is_deeply( [ remote()->list_dir("$dir/none; echo leaked") ], [],         'where a semicolon is part of the name, not the end of a command' );
};

subtest 'is_dir and is_block_device ask the machine that has the path' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my ( $machine, $mock ) = here();
    is( $machine->is_dir($dir),              1, 'a directory here is one' );
    is( $machine->is_dir("$dir/none"),       0, 'and a path that is not there is not' );
    is( $machine->is_block_device($dir),     0, 'a directory is no block device' );
    is( $machine->is_block_device('/bogus'), 0, 'and neither is a path that is not there' );
    undef $mock;    ## no critic (ProhibitUselessVarClearing) -- restores the real is_local, so that remote() below is not taken for this machine

    # The far side runs test(1) with the path as one argument, and its exit
    # status is the answer.  Here a local shell stands in for it.
    my @ran;
    my $remote = Test::MockModule->new('Trog::Machine');
    $remote->redefine( run_cmd => sub ( $, @argv ) { push @ran, [@argv]; return system(@argv) >> 8 } );
    is( remote()->is_dir($dir),          1, 'a directory there is one' );
    is( remote()->is_dir("$dir/none"),   0, 'and a path that is not there is not' );
    is( remote()->is_block_device($dir), 0, 'a directory there is no block device' );
    is_deeply( $ran[0], [ 'test', '-d', $dir ], 'each is one test(1) on the far side' );
    is_deeply( $ran[2], [ 'test', '-b', $dir ], 'with the flag that asks for a block device' );
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

subtest 'a remote sudo that could ask for a password is refused before it is sent' => sub {

    # Over ssh nobody can type a password, so a sudo that asks for one waits
    # until the alarm, ten minutes later.
    my @sent;
    my $far = Test::MockModule->new( 'Trog::Machine::FarSide', no_auto => 1 );
    $far->define( cmd           => sub ( $,     @command ) { push @sent, "@command"; return ( "ok\n", q{}, 0 ) } );
    $far->define( cmd_exit_code => sub ( $self, @command ) { return ( $self->cmd(@command) )[2] } );
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( ssh => sub { return bless {}, 'Trog::Machine::FarSide' } );

    like( exception { remote()->capture_cmd(q{sudo cat /bogus/file}) }, qr/sudo[ ]-n .* run_sudo/, 'capture_cmd refuses a sudo with no -n, and says what to use instead' );
    like( exception { remote()->run_cmd(qw{sudo true}) },               qr/sudo[ ]-n/,             'and so does run_cmd with a list' );
    like( exception { remote()->run_cmd(q{  sudo true}) },              qr/sudo[ ]-n/,             'and with a string that starts with blanks' );
    is( scalar @sent, 0, 'and none of them was sent' ) or diag explain \@sent;

    is( remote()->capture_cmd(q{sudo -n cat /bogus/file}), "ok\n", 'a sudo -n is sent, because it fails at once when it would ask' );
    is( remote()->run_cmd(qw{sudo -n true}),               0,      'by run_cmd too' );
    is( remote()->capture_cmd(q{sudo -V}),                 "ok\n", 'and so is sudo -V, which asks for nothing, and refuses -n' );
    is( remote()->capture_cmd(q{sudoedit-ish /bogus}),     "ok\n", 'and a command that only starts with the letters is not sudo' );
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

# What a caller can put in an argument.  None of it is special to a list.
my @AWKWARD = ( q{plain}, q{it's}, q{say "hi"}, q{a b}, qq{two\nlines}, q{$HOME `x` ; | & \\}, q{} );

subtest 'capture_cmd on this machine: a list reaches the program as it was written' => sub {
    require Trog::Local;
    my $here = Trog::Local->new;

    foreach my $word (@AWKWARD) {
        is( $here->capture_cmd( 'printf', '%s', $word ), $word, 'an argument of ' . ( $word ne q{} ? ( $word =~ s/\n/\\n/gr ) : 'nothing' ) . ' arrives unchanged' );
    }
    is( $here->capture_cmd( 'printf', '%s|%s|%s', "a b", q{'}, q{"} ), q{a b|'|"}, 'and each one stays one argument' );
};

subtest 'capture_cmd on this machine: one string is still a shell command' => sub {
    require Trog::Local;
    my $here = Trog::Local->new;

    is( $here->capture_cmd(q{printf 'a\nb\nc\n' | tail -n1}), "c\n", 'a pipeline runs' );
    is( $here->capture_cmd(q{echo "$$" | grep -c .}),         "1\n", 'and so does the expansion of a variable' );
    is( $here->capture_cmd( 'false', 'x' ),                   q{},   'a list with a program that fails says nothing' );
    is( $here->capture_cmd( '/bogus/not-a-program', 'x' ),    q{},   'and so does one that is not there, as the shell would give it' );
};

subtest 'capture_quiet on this machine: standard error goes, and standard output stays' => sub {
    require Trog::Local;
    my $here = Trog::Local->new;

    my ( $out, $loud ) = ( q{}, q{} );
    $loud = capture_stderr { $out = $here->capture_cmd( qw{sh -c}, 'echo said; echo complained >&2' ) };
    is_deeply( [ $out, $loud ], [ "said\n", "complained\n" ], 'capture_cmd leaves it to the terminal' );

    my $quiet = capture_stderr { $out = $here->capture_quiet( qw{sh -c}, 'echo said; echo complained >&2' ) };
    is_deeply( [ $out, $quiet ], [ "said\n", q{} ], 'capture_quiet throws it away, with no shell redirect' );
};

subtest 'capture_with_input: the input on standard input, here and over ssh' => sub {
    require Trog::Local;
    my $big = 'x' x 200_000;
    is_deeply( [ Trog::Local->new->capture_with_input( $big, qw{sh -c}, 'wc -c; echo said >&2' ) ], [ "200000\n", "said\n" ], 'here, more than an argument can hold, with standard error apart' );

    my @sent;
    my $far = Test::MockModule->new( 'Trog::Machine::FarSide', no_auto => 1 );
    $far->define( capture2 => sub ( $, $opts, @command ) { push @sent, [ $opts, @command ]; return ( "out\n", "err\n" ) } );
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( ssh => sub { return bless {}, 'Trog::Machine::FarSide' } );

    is_deeply( [ remote()->capture_with_input( '{"a":1}', 'perl', '/bogus/ippool' ) ], [ "out\n", "err\n" ],                                                         'over ssh, both streams come back' );
    is_deeply( \@sent,                                                                 [ [ { timeout => 120, stdin_data => '{"a":1}' }, 'perl', '/bogus/ippool' ] ], 'and the input goes as stdin_data of a command with no terminal' );
    like( exception { remote()->capture_with_input( q{}, qw{sudo true} ) }, qr/Refusing[ ]to[ ]send/, 'and a sudo that can ask is refused' );
};

subtest 'capture_sudo: sudo -n, and never a sudo that asks' => sub {
    my @asked;
    my $mock = Test::MockModule->new('Trog::Machine');
    $mock->redefine( capture_cmd => sub ( $self, @argv ) { push @asked, [@argv]; return "out\n" } );

    is( remote()->capture_sudo( 'cat', q{/bogus/it's} ), "out\n", 'it returns standard output, as capture_cmd does' );
    is_deeply( \@asked, [ [ qw{sudo -n cat}, q{/bogus/it's} ] ], 'with -n in front, and the arguments as they were' );
};

subtest 'a remote list is sent to ssh as a list, and passes the sudo guard' => sub {
    my @sent;
    my $far = Test::MockModule->new( 'Trog::Machine::FarSide', no_auto => 1 );
    $far->define( cmd => sub ( $, @command ) { push @sent, [@command]; return ( "ok\n", q{}, 0 ) } );
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( ssh => sub { return bless {}, 'Trog::Machine::FarSide' } );

    foreach my $word (@AWKWARD) {
        @sent = ();
        remote()->capture_cmd( 'printf', '%s', $word );
        is_deeply( \@sent, [ [ 'env', @Trog::Machine::NO_PAGER, 'printf', '%s', $word ] ], 'an argument of ' . ( $word ne q{} ? ( $word =~ s/\n/\\n/gr ) : 'nothing' ) . ' is one element, with no quoting of ours' );
    }

    @sent = ();
    remote()->capture_cmd(q{ls | wc -l});
    is_deeply( \@sent, [ ["export @Trog::Machine::NO_PAGER; ls | wc -l"] ], 'a single string stays one string, for the shell of the far side' );

    @sent = ();
    is( remote()->capture_sudo( qw{sh -c}, q{echo 'x'; echo "y"} ), "ok\n", 'capture_sudo passes the guard' );
    is_deeply( \@sent, [ [ 'env', @Trog::Machine::NO_PAGER, qw{sudo -n sh -c}, q{echo 'x'; echo "y"} ] ], 'and the script is one element' );

    @sent = ();
    like( exception { remote()->capture_cmd(qw{sudo cat /bogus}) }, qr/sudo[ ]-n/, 'a list that starts with sudo and no -n is refused' );
    is( scalar @sent, 0, 'and not sent' );

    @sent = ();
    remote()->capture_quiet( qw{ls -1}, '/bogus' );
    is_deeply( \@sent, [ [ 'env', @Trog::Machine::NO_PAGER, qw{ls -1 /bogus} ] ], 'capture_quiet sends the same command, since ssh keeps standard error apart' );
};

# The file is usually authorized_keys, where one wrong write locks its owner
# out, so each way out is checked for what it leaves on disk.
Test::NoWarnings::had_no_warnings();
done_testing();
