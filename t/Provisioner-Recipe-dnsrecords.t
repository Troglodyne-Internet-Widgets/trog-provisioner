#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-dnsrecords.t - which guests publish their own records, and
which have nothing to publish

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

my %COMMON = (
    install_dir  => '/opt/domains',
    admin_user   => 'doge',
    script_dir   => '/root/bin',
    full_aliases => [ 'www.pub.test', 'mail.pub.test' ],
);

# A fresh recipe per case: validated() memoises onto the object, so a second
# render through the same one answers with the first one's options.
sub fresh {
    return Provisioner::Cookbook->load( 'dnsrecords', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'a guest with an address publishes it, whoever holds the zone' => sub {
    my %opts = fresh()->validate( %COMMON, domain => 'pub.test', main_ip => '192.168.1.50' );

    # .test is served by the guest's own pdns, and this used to stay out of the
    # way for exactly that -- on the grounds that the zonefile had already
    # written the same records.  True of a first build and false of every one
    # after it: pdns loads the zonefile only into a database that does not
    # already answer for the domain, so a restored zones.db keeps an address
    # that has since changed, and nothing else corrects it.
    is( $opts{publish_records}, 1, 'including one whose zone its own pdns serves' );
};

subtest 'a guest whose address the hypervisor allocates has nothing to publish' => sub {

    # main_ip is nullable for exactly this: a cloud gives the guest its address
    # when it creates it, so there is none at the time the makefile is written.
    my %opts = fresh()->validate( %COMMON, domain => 'pub.test', main_ip => undef );

    is( $opts{publish_records}, 0, 'so it is left alone rather than guessed at' );
};

subtest 'the fragment queues the publish where there is one, and nothing where there is not' => sub {
    my $queued = fresh()->render( %COMMON, domain => 'pub.test', main_ip => '192.168.1.50' );

    like( $queued, qr/queue_postrun_task/,    'it is deferred to the postrun, where the shortcut and the provider are both settled' );
    like( $queued, qr/publish_dns_records/,   'running the publisher' );
    like( $queued, qr/[ ]192[.]168[.]1[.]50/, 'with the address the guest was built with' );
    like( $queued, qr/[ ]mail[.]pub[.]test/,  'and each alias, sorted' );

    my $nothing = fresh()->render( %COMMON, domain => 'pub.test', main_ip => undef );
    unlike( $nothing, qr/\S/, 'and with no address the fragment is empty rather than a target that does nothing' );
};

subtest 'it depends on the client it writes the records with' => sub {
    my %required = fresh()->required_recipes( %COMMON, domain => 'pub.test' );

    ok( exists $required{lexicon}, 'lexicon, which installs both the client and the shortcut holding the credential' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
