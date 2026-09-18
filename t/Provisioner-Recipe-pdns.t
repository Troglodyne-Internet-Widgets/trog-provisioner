#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-pdns.t - the zone this recipe builds: which names in it are
absolute, and which are deliberately not

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
use Provisioner::Recipe::pdns();

# These patterns quotemeta a literal on purpose: a fixture domain full of dots
# that would otherwise need escaping one at a time.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

my $DOMAIN = 'zone.test';

# What bin/new_config hands the zone template.  Aliases arrive fully qualified:
# new_config appends www and mail to the domain itself, and whatever ipmap.cfg
# names is spelled out in full as well.
my %VARS = (
    domain      => $DOMAIN,
    admin_email => 'doge@zone.test',
    ipmap       => { $DOMAIN => '192.168.1.50' },
    aliases     => { $DOMAIN => [ "www.$DOMAIN", "mail.$DOMAIN" ] },
    nameservers => {},
    modules     => [],
    install_dir => '/opt/domains',
    admin_user  => 'doge',
);

sub zone {
    my (%over) = @_;

    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    return $recipe->render_file( 'files/pdns.zone.tt', %VARS, %over, api_key => 'a-key' );
}

subtest 'a name given in full is emitted absolute' => sub {
    my $zone = zone();

    # The zonefile opens with $ORIGIN <domain>., so a name without a trailing
    # dot has the origin put on it again.  An alias is already the whole name,
    # so relative made www.zone.test answer as www.zone.test.zone.test -- and
    # nothing resolved www.zone.test at all.  Measured on a guest.
    like( $zone, qr/^\Qwww.$DOMAIN\E\.\s+IN\s+CNAME\s+\@/m,  'an alias CNAME ends in a dot' );
    like( $zone, qr/^\Qmail.$DOMAIN\E\.\s+IN\s+CNAME\s+\@/m, 'each of them' );

    # The MX target had the same fault, while every SRV target beside it was
    # already absolute.  Asked of a zone that serves mail, which is the only
    # kind that has an MX to get wrong.
    my $mail = zone( modules => ['mail'] );
    like( $mail, qr/IN\s+MX\s+10\s+\Qmail.$DOMAIN\E\./, 'the MX target ends in a dot' );

    # One assertion for the whole class, so a third instance is caught without
    # anybody having to think of it: nothing in either zone carries the origin
    # twice.
    unlike( $zone, qr/\Q$DOMAIN.$DOMAIN\E/, 'and no name in the zone has the origin on it twice' )
      or diag $zone;
    unlike( $mail, qr/\Q$DOMAIN.$DOMAIN\E/, 'nor in the mail records beside them' )
      or diag $mail;
};

subtest 'a label that belongs to the zone stays relative' => sub {
    my $zone = zone();

    # The opposite mistake.  These are labels rather than names, so a trailing
    # dot would make each of them a name at the root instead.
    like( $zone, qr/^ns1\s+IN\s+A\s/m, 'ns1 is a label' );

    # The template carries the zone and invents no names: what a recipe serves
    # it declares, and bin/new_config puts it in the aliases rendered above.
    unlike( $zone, qr/^autodiscover\s+IN\s+CNAME/m, 'it no longer invents autodiscover for a domain that serves no mail' );
    unlike( $zone, qr/^autoconfig\s+IN\s+CNAME/m,   'nor autoconfig' );
    unlike( $zone, qr/matrix/,                      'nor a matrix block of its own' );

    # Absolute already, and the pattern the MX record above should have
    # followed.  Asked of a zone that serves mail: the SRVs are written only
    # where something answers on the name they point at.
    like( zone( modules => ['mail'] ), qr/^_imaps\._tcp\s+IN\s+SRV\s+0\s+0\s+993\s+\Qmail.$DOMAIN\E\./m, 'an SRV target is absolute' );
};

subtest 'a record points only at a name the guest actually has' => sub {

    # The MX, the five SRVs and the autoconfig TXT all name a host the mail
    # recipe declares, so on a domain running no mail they would point at a name
    # with no record at all.
    my $without = zone();

    unlike( $without, qr/IN\s+MX\s/,  'no MX where nothing serves mail' ) or diag $without;
    unlike( $without, qr/IN\s+SRV\s/, 'nor the mail SRVs' )               or diag $without;
    unlike( $without, qr/mailconf=/,  'nor an autoconfig URL for a name nothing answers on' );
    unlike( $without, qr/_domainkey/, 'nor DKIM placeholders' );

    my $with = zone( modules => ['mail'] );

    like( $with, qr/IN\s+MX\s+10\s+\Qmail.$DOMAIN\E\./, 'and the MX is there where mail is served' );
    like( $with, qr/^_imaps\._tcp\s+IN\s+SRV/m,         'with the SRVs beside it' );
    like( $with, qr/mailconf=/,                         'and the autoconfig record' );
};

subtest 'the apex is the origin, not a name of its own' => sub {
    my $zone = zone();

    like( $zone, qr/^\$ORIGIN\s+\Q$DOMAIN\E\./m,               'the zone declares its origin' );
    like( $zone, qr/^\@\s+IN\s+A\s+192\.168\.1\.50/m,          'and the address is on the apex' );
    like( $zone, qr/^\@\s+300\s+IN\s+NS\s+\Qns1.$DOMAIN\E\./m, 'with an absolute nameserver' );
};

subtest 'the submission SRV record names the port postfix listens on' => sub {

    # Asked of a zone that serves mail, since the mail records are written only
    # where something answers on the name they point at.
    my $zone = zone( modules => ['mail'] );

    # RFC 6186 spells it _submission._tcp, and mail.postfix.master.tt runs
    # submission on 587.
    my ($record) = $zone =~ m/^(_submission\N*)$/m;
    is( ( split ' ', $record // q{} )[0], '_submission._tcp', 'on _submission._tcp' ) or diag $zone;
    like( $record, qr/SRV\s+0\s+0\s+587\s+\Qmail.$DOMAIN\E\./, 'at port 587 on the mail host' );
};

subtest 'synczones and the API config name the socket the recipe binds' => sub {
    local $Provisioner::Recipe::pdns::API_SOCKET = '/bogus/api.sock';
    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    like( $recipe->render_file( 'files/pdns.synczones.tt', %VARS, api_key => 'a-key' ), qr{^server=local:/bogus/api[.]sock$}m, 'synczones reads it from $API_SOCKET' );
    like( $recipe->render_file( 'files/pdns.api.tt',       %VARS, api_key => 'a-key' ), qr{/bogus/api[.]sock},                 'and so does the API config' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
