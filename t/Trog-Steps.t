#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-Steps.t - the steps of the recipes of a domain on other machines: which
run, when, on which machine, and what a dry run and a teardown do with them

=head1 DESCRIPTION

The recipes here are fakes, and so is the configuration that names them, so
that each assertion is about the runner and not about what a real recipe asks
for.  The tests of each recipe cover its own steps.

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture_stdout};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use FindBin::libs;

## no critic (CompileTime) -- set before anything reads the configuration directory.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Provisioner::Cookbook();                                                                         ## no critic (ProhibitUnusedImports) -- loaded so that Test::MockModule has a package to attach to
use Trog::HV();
use_ok(q{Trog::Steps});

# What every action did, in order, across the recipes below.
my @DID;

# An action that records its sentence when it runs, and is done when $done says.
sub action ( $what, $done = 0 ) {
    return { what => $what, done => sub { $done }, do => sub { push @DID, $what } };
}

# The steps of each fake recipe, by its name.  A test sets them.
my %STEPS;
{

    package Test::Recipe::Outside;
    sub outside_steps ( $, $, %opts ) { return @{ $STEPS{ $opts{name} } // [] } }
    sub sends_mail                    { return 0 }

    # A recipe that sends mail, and has steps of its own as well.
    package Test::Recipe::Mailer;
    use parent -norequire, 'Test::Recipe::Outside';
    sub sends_mail { return 1 }
}

my $dir = tempdir( CLEANUP => 1 );
Trog::HV->forget();
Trog::HV->new( uri => 'qemu+ssh://root@hv.test.test/system', domain_dir => $dir );

# Two recipes, b and a, on one domain.  Each reads its own name out of its
# block, which is how a real recipe reads its configuration.
my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
$cookbook->redefine( domain_config => sub { return { b => { name => 'b' }, a => { name => 'a' }, _global => {} } } );
$cookbook->redefine( has  => sub { my ( undef, $name ) = @_; return $name ne '_global' } );
$cookbook->redefine( load => sub { my ( undef, $name ) = @_; return $name =~ m/\Amail/ ? 'Test::Recipe::Mailer' : 'Test::Recipe::Outside' } );

subtest 'the steps of a domain are those of its recipes, and one id is one step' => sub {
    %STEPS = (
        a => [ { id => 'same', machine => 'hypervisor', when => 'built', apply => sub { action('from a') } } ],
        b => [
            { id => 'same', machine => 'hypervisor', when => 'built', apply => sub { action('from b') } },
            { machine => 'hypervisor', when => 'built', apply => sub { action('b alone') } },
        ],
    );
    @DID = ();
    capture_stdout { Trog::Steps->apply( 'vm.test.test', when => 'built' ) };
    is_deeply( \@DID, [ 'from a', 'b alone' ], 'in the order of the recipe names, with a step under one id done once' );
};

subtest 'a step runs at its moment, and only an action that is not done' => sub {
    my %given;
    %STEPS = (
        a => [
            {
                machine => 'hypervisor',
                when    => 'secrets',
                apply   => sub ( $machine, %context ) { %given = ( machine => $machine, %context ); return ( action( 'there already', 1 ), action('missing') ) },
            },
            { machine => 'hypervisor', when => 'built',   apply  => sub { action('after the build') } },
            { machine => 'hypervisor', when => 'secrets', revert => sub { action('only taken back') } },
        ],
    );
    @DID = ();
    my $said = capture_stdout { is( Trog::Steps->apply( 'vm.test.test', when => 'secrets', secrets => { 'secret:a/b/password' => 'x' } ), 1, 'one action ran' ) };
    is_deeply( \@DID, ['missing'], 'the one that was not done, and nothing of the other moment, or of a step with nothing to apply' );
    like( $said, qr/^[ ]+ok[ ]+there[ ]already$/m, 'and it says which was done already' );
    like( $said, qr/^[ ]+now[ ]+missing$/m,        'and which it did' );

    is( $given{machine},    Trog::HV->new(),     "'hypervisor' is the hypervisor of this run" );
    is( $given{domain_dir}, "$dir/vm.test.test", 'the step gets the directory of the domain' );
    is_deeply( $given{secrets}, { 'secret:a/b/password' => 'x' }, 'and the secrets that it was handed' );

    like( exception { Trog::Steps->apply( 'vm.test.test', when => 'later' ) }, qr/needs[ ]a[ ]when/, 'a moment that does not exist is refused' );
};

subtest 'a dry run asks and says, and does nothing' => sub {
    %STEPS = ( a => [ { machine => 'hypervisor', when => 'secrets', apply => sub ( $m, %context ) { $context{dryrun} ? action('missing') : () } } ] );
    @DID   = ();
    my $said = capture_stdout { Trog::Steps->apply( 'vm.test.test', when => 'secrets', dryrun => 1 ) };
    is_deeply( \@DID, [], 'nothing ran' );
    like( $said, qr/^[ ]+would[ ]+missing$/m, 'and it says what would' );
};

subtest 'a preview is a dry run of every moment, in the order of a provision' => sub {
    %STEPS = (
        a => [
            { machine => 'hypervisor', when => 'built',   apply => sub { action('after') } },
            { machine => 'hypervisor', when => 'secrets', apply => sub { action('before') } },
        ],
    );
    @DID = ();
    my $said;
    $said = capture_stdout { is( Trog::Steps->preview('vm.test.test'), 2, 'two actions would run' ) };
    is_deeply( \@DID, [], 'and none did' );
    is( $said, "What vm.test.test needs on other machines:\n  would before\n  would after\n", 'the moment before the makefile first' );

    %STEPS = ( a => [ { machine => 'hypervisor', when => 'secrets', revert => sub { action('undo') } } ] );
    is( Trog::Steps->preview('vm.test.test'), 0, 'a domain with only reverts has nothing to preview' );
};

subtest 'an action that dies stops the provision' => sub {
    %STEPS = (
        a => [
            {
                machine => 'hypervisor',
                when    => 'secrets',
                apply   => sub {
                    { what => 'break', done => sub { 0 }, do => sub { die "it broke\n" } }
                }
            }
        ]
    );
    like(
        exception {
            capture_stdout { Trog::Steps->apply( 'vm.test.test', when => 'secrets' ) }
        },
        qr/it[ ]broke/,
        'with what it said'
    );
};

subtest 'a teardown takes back the last step first, and goes on past one that fails' => sub {
    %STEPS = (
        a => [
            { machine => 'hypervisor', when => 'secrets', revert => sub { action('undo first') } },
            { machine => 'hypervisor', when => 'secrets', revert => sub { die "the hypervisor said no\n" } },
            { machine => 'hypervisor', when => 'secrets', revert => sub ( $m, %context ) { %{ $context{secrets} } ? () : action('undo last') } },
        ],
    );
    @DID = ();
    my $warned = q{};
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    capture_stdout { Trog::Steps->revert('vm.test.test') };
    is_deeply( \@DID, [ 'undo last', 'undo first' ], 'in the other order, and with no secrets, so a teardown never opens the store' );
    is( $warned, "Could not undo a step of vm.test.test on the hypervisor of this run: the hypervisor said no\n", 'the one that failed is a warning that names the machine' );
};

subtest 'a step names a hypervisor of the fleet, as the account of its block' => sub {
    my $hvconf = "$dir/hypervisors.conf";
    File::Slurper::Temp::write_text( $hvconf, "[hv1]\nlibvirt_uri = qemu+ssh://someadmin\@hv1.test.test/system\n" );

    my ( $named, $by_uri );
    %STEPS = (
        a => [
            { machine => { hypervisor => 'hv1' },                                    when => 'secrets', apply => sub ( $m, %c ) { $named  = $m; () } },
            { machine => { uri        => 'qemu+ssh://runner@hv1.test.test/system' }, when => 'secrets', apply => sub ( $m, %c ) { $by_uri = $m; () } },
        ],
    );
    Trog::Steps->apply( 'vm.test.test', when => 'secrets', hvconf => $hvconf );
    is( $named->ssh_user,  'someadmin', 'the block of hypervisors.conf, as the account that the block names' );
    is( $by_uri->ssh_user, 'runner',    'and a URI as its own user' );

    like(
        exception { Trog::Steps->apply( 'vm.test.test', when => 'secrets', hvconf => "$dir/none.conf" ) },
        qr/there[ ]is[ ]no[ ]such[ ]file/,
        'a hypervisor by name with no fleet to find it in is refused, rather than taken to be this machine'
    );
};

# --- The reverse DNS of a guest that sends mail ---

subtest 'a recipe that sends mail gets the reverse DNS, whatever steps of its own it has' => sub {
    %STEPS = ( mail => [ { id => 'own', machine => 'hypervisor', when => 'secrets', apply => sub { action('its own') } } ] );
    my $config = Test::MockModule->new('Provisioner::Cookbook');
    $config->redefine( domain_config => sub { return { mail => { name => 'mail' }, mailrelay => { name => 'mailrelay' }, nginx => { name => 'nginx' } } } );

    my @steps = Trog::Steps->of('mx.test.test');
    is_deeply( [ map { $_->{id} } @steps ], [qw{own reverse_dns}], 'its own step, and the reverse DNS once, for two recipes that send mail' );
    is( $steps[1]{when}, 'built', 'after the build, because the build publishes the name' );

    $config->redefine( domain_config => sub { return { nginx => { name => 'nginx' } } } );
    is_deeply( [ Trog::Steps->of('mx.test.test') ], [], 'and a guest that sends no mail gets none' );
};

subtest 'the reverse DNS of a guest is set to the name its mail announces' => sub {
    %STEPS = ();
    my ( %host, $answer, @asked );
    my $config = Test::MockModule->new('Provisioner::Cookbook');
    $config->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $domain eq 'mx.test.test' ? { mail => { name => 'mail' } } : { mailrelay => { name => 'mailrelay' } } } );
    $config->redefine( host_of       => sub { my ( undef, $domain ) = @_; return $host{$domain} } );
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( set_reverse_dns => sub { my ( undef, @args ) = @_; push @asked, \@args; return $answer->() } );

    # What the step printed and warned, after the build of $domain at $address.
    # A warning is caught by name, because Test::NoWarnings takes it before
    # it reaches stderr.
    my $point = sub ( $address, $domain = 'mx.test.test' ) {
        @asked = ();
        my $err = q{};
        local $SIG{__WARN__} = sub { $err .= $_[0] };
        my $out = capture_stdout { Trog::Steps->apply( $domain, when => 'built', address => $address ) };
        $out =~ s/^[ ]+now[ ][^\n]*\n//m;
        return ( $out, $err );
    };

    $answer = sub { '9.9.9.9' };
    my ( $out, $err ) = $point->('9.9.9.9');
    is_deeply( \@asked, [ [ 'mx.test.test', 'mail.mx.test.test' ] ], 'set to the name that its postfix announces' );
    is( $out, "The reverse DNS of 9.9.9.9 is now mail.mx.test.test\n", 'and it says so' );

    %host = ( 'tenant.test.test' => 'mx.test.test' );
    $point->( '9.9.9.9', 'tenant.test.test' );
    is( $asked[0][0], 'mx.test.test', 'a tenant that sends mail gets it on the guest of its host' );
    %host = ();

    $answer = sub { die "the hypervisor refused: 403 not authorized\n" };
    ( $out, $err ) = $point->( '9.9.9.9', 'relay.test.test' );
    is( $err, "Could not set the reverse DNS of relay.test.test to relay.test.test, so receivers can reject its mail.\nthe hypervisor refused: 403 not authorized\n", 'a refusal is a warning with what the hypervisor said, and does not stop the run' );

    $answer = sub { return };
    ( $out, $err ) = $point->( '9.9.9.9', 'relay.test.test' );
    is(
        $out,
        "Set the reverse DNS of 9.9.9.9 to relay.test.test where the address is held.  " . Trog::HV->new()->describe . " offers no way to do it from here, and until it is set, receivers can reject the mail of relay.test.test.\n",
        'a hypervisor that offers no way has the operator told what to set, for a public address'
    );

    ( $out, $err ) = $point->( '192.168.1.20', 'relay.test.test' );
    is( $out . $err, q{}, 'but not for a private one, which no receiver sees' );
};

had_no_warnings();
done_testing();
