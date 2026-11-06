#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-servicesudo.t - the commands that the C<servicesudo> recipe
lets the service user run as root, and the ones that it refuses

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use IPC::Run3();
use File::Which();

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain      => 'agent.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'admin',
    user        => 'svc',
);

sub recipe {
    return Provisioner::Cookbook->load( 'servicesudo', distro => 'ubuntu' )->new(%PROV);
}

# What visudo makes of a rendered file, rather than what the file looks like.
# /usr/sbin by name, because it is not on the PATH of every user.
my $visudo = File::Which::which('visudo') // File::Which::which('/usr/sbin/visudo');

sub parses {
    my ($sudoers) = @_;
    my $file = File::Temp->new;
    print {$file} $sudoers;
    close $file or die "Could not write $file: $!";
    IPC::Run3::run3( [ $visudo, '-cf', $file->filename ], \undef, \my $out, \my $err );
    return ( $? >> 8 == 0, "$out$err" );
}

subtest 'commands' => sub {
    my @commands = ( '/usr/bin/systemctl restart ssh', '/usr/bin/id ""', '/usr/bin/cat /var/log/syslog' );
    my $sudoers  = recipe()->render_file( 'files/servicesudo.sudoers.tt', %G, commands => \@commands );
    foreach my $command (@commands) {
        like( $sudoers, qr/^svc[ ]ALL=\(root\)[ ]NOPASSWD:[ ]\Q$command\E$/m, "the service user may run $command as root" ) or diag $sudoers;
    }
    unlike( $sudoers, qr/&quot;/, 'and a command with no arguments keeps its quotes' );

    my $none = recipe()->render_file( 'files/servicesudo.sudoers.tt', %G );
    unlike( $none, qr/^[^#\n]/m, 'with no commands, the file grants nothing' ) or diag $none;

  SKIP: {
        skip 'no visudo here', 2 unless $visudo;
        my ( $ok, $said ) = parses($sudoers);
        ok( $ok, 'visudo reads the grant' ) or diag $said;
        ( $ok, $said ) = parses($none);
        ok( $ok, 'and the file with none' ) or diag $said;
    }
};

# The boundary: the obvious mistakes, and nothing that sudo reads for itself.
subtest 'a command that is plainly wrong is refused' => sub {
    my %refused = (
        'ALL'                      => 'ALL',
        'usr/bin/id'               => 'a relative path',
        '!/usr/bin/id'             => 'a negation',
        "/usr/bin/id\n"            => 'a trailing newline',
        "/usr/bin/id\nsvc ALL=ALL" => 'a second line',
        '/usr/bin/id, /bin/sh'     => 'a comma, which starts a second command',
        '/usr/bin/id  x'           => 'two spaces, which is an empty argument',
        '/usr/bin/id '             => 'a trailing space',
    );
    foreach my $command ( sort keys %refused ) {
        like( exception { recipe()->validate( %G, commands => [$command] ) }, qr{/commands/0:}, "$refused{$command} is refused" );
    }
    like( exception { recipe()->validate( %G, commands => [ '/usr/bin/id', '/usr/bin/id' ] ) }, qr{/commands:}, 'and so is a command named twice' );

    my %taken = (
        '/usr/bin/systemctl restart ssh' => 'a command with arguments',
        '/usr/bin/id ""'                 => 'a command with no arguments allowed',
        '/usr/bin/ls /var/..'            => 'a .. in an argument, which sudo matches as written',
        '/usr/bin/id'                    => 'a command alone',
        '/usr/bin/systemctl restart *'   => 'a wildcard, which the operator can mean',
    );
    foreach my $command ( sort keys %taken ) {
        is( exception { recipe()->validate( %G, commands => [$command] ) }, undef, "$taken{$command} is taken" );
    }

    is_deeply( { recipe()->validate(%G) }->{commands}, [], 'and the default is none' );
};

subtest 'a domain with no service user' => sub {
    my %without = %G;
    delete $without{user};
    my %opts = recipe()->validate( %without, commands => ['/usr/bin/id'] );
    is( $opts{user}, $G{admin_user}, 'falls back to the admin' );
    my $fragment = recipe()->render_file( 'ubuntu/servicesudo.tt', %opts );
    unlike( $fragment, qr/\S/, 'and installs nothing, because the admin has sudo for everything already' ) or diag $fragment;
    my $sudoers = recipe()->render_file( 'files/servicesudo.sudoers.tt', %opts );
    unlike( $sudoers, qr/^[^#\n]/m, 'and its sudoers file grants nothing either' ) or diag $sudoers;
    like( recipe()->render_file( 'ubuntu/servicesudo.tt', recipe()->validate(%G) ), qr{^install[ ].*/etc/sudoers[.]d/servicesudo-svc$}m, 'while a service user gets its file' );

    my $test = recipe()->render_file( 'tests/servicesudo.tt', %opts );
    like( $test, qr/^plan[ ]skip_all/m, 'and the guest test skips' );

    like( exception { recipe()->validate( %G, user => 'a.b' ) }, qr/not[ ]a[ ]name/, 'a user that sudo would skip the file of is refused' );
};

# What each recipe whose units run as the service user asks for, and what
# servicesudo and visudo make of it.
subtest 'the units of the recipes that run as the service user' => sub {
    is_deeply(
        [ Provisioner::Recipe::servicesudo::unit_commands('x.test.service') ],
        [ '/usr/bin/systemctl restart x.test.service', '/usr/bin/systemctl status x.test.service' ],
        'a unit can be restarted and asked for its status, and nothing else'
    );

    my %units = (
        clod  => [qw{clod-agent.test.test.service clod-worker-agent.test.test.service}],
        koan  => [qw{koan.service koan-awake.service}],
        tpsgi => [qw{agent.test.test.service}],
    );

    # clod also lets its service user install system packages, through one
    # program of root's that checks every name it is given.
    my %more = ( clod => ['/usr/local/sbin/clod-install-packages'] );
    foreach my $name ( sort keys %units ) {
        my %required = Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(%PROV)->required_recipes(%G);
        ok( ref $required{servicesudo} eq 'CODE', "$name requires servicesudo" ) or next;
        my %asked = $required{servicesudo}->(%G);
        is_deeply( $asked{commands}, [ Provisioner::Recipe::servicesudo::unit_commands( @{ $units{$name} } ), @{ $more{$name} // [] } ], "for its own units: @{ $units{$name} }" );

        my %opts = eval { recipe()->validate( %G, %asked ) };
        ok( %opts, "which servicesudo takes" ) or diag $@;
      SKIP: {
            skip 'no visudo here', 1 unless $visudo;
            my ( $ok, $said ) = parses( recipe()->render_file( 'files/servicesudo.sudoers.tt', %opts ) );
            ok( $ok, 'and visudo reads' ) or diag $said;
        }
    }
};

done_testing();
