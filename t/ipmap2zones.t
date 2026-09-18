#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/ipmap2zones.t - bin/ipmap2zones: which domain it is asked about, and which
names and records end up in the zone it writes

=cut

# Asserting a zone file was written is what this does, and -f is how you ask.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: this reads recipes.yaml to find
# out what each domain runs, and the address database beside it.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stdout};
use File::Temp    qw{tempdir tempfile};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();
use Provisioner::IPPool();

my $script = "$FindBin::Bin/../bin/ipmap2zones";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# Three domains: one that serves the web, one that serves mail, and one that
# serves neither.
File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    YAML::XS::Dump(
        {
            'web.test'   => { nginx => undef },
            'post.test'  => { mail  => undef },
            'plain.test' => { ntp   => undef },
        }
    )
);
Provisioner::Cookbook->forget();

# The addresses live in ips.db rather than in an [ips] section, which is where
# the script reads them from.
Provisioner::IPPool::record( '192.168.1.60', 'web.test' );
Provisioner::IPPool::record( '192.168.1.61', 'plain.test' );
Provisioner::IPPool::record( '192.168.1.62', 'post.test' );

my ( $ih, $ipmap_file ) = tempfile();
print {$ih} <<'IPMAP';
[global]
admin_email=doge@test.test
[nameservers]
ns1=ns1.test.test
IPMAP
close($ih) or BAIL_OUT("Cannot close $ipmap_file: $!");

# The zone it writes for one domain, as text.  What it answered with is not
# interesting: it dies on anything it cannot do, which the subtests below check
# for directly.
sub zone_for {
    my ($domain) = @_;

    my $out = tempdir( CLEANUP => 1 );
    capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--ipmap', $ipmap_file, '--output-dir', $out, $domain ) };

    my $file = "$out/$domain.zone";

    return -f $file ? File::Slurper::read_text($file) : undef;
}

subtest 'a domain has to be named' => sub {

    # It generated for every domain in [ips] when given none.  That was
    # answerable while every zone carried the same www and mail; now the names
    # are the ones that domain's recipes declare, so the answer is per domain.
    like(
        exception { Trog::Provisioner::IPMap2Zones::main( '--ipmap', $ipmap_file ) },
        qr/Name[ ]at[ ]least[ ]one[ ]domain/,
        'naming none is refused rather than answered for all of them'
    );
};

subtest 'the zone carries the names that domain serves' => sub {
    my $out = tempdir( CLEANUP => 1 );
    my ($said) = capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--ipmap', $ipmap_file, '--output-dir', $out, 'web.test' ) };
    like( $said, qr/web[.]test[.]zone/, 'it says which file it wrote' );

    my $zone = File::Slurper::read_text("$out/web.test.zone");

    like( $zone, qr/^www[.]web[.]test\.\s+IN\s+CNAME\s+\@/m, 'www, because nginx serves it' ) or diag $zone;

    # And absolute, which is the other thing this template gets wrong when
    # nobody is looking: $ORIGIN is the domain, so a relative name has it put
    # on again.
    unlike( $zone, qr/web[.]test[.]web[.]test/, 'and no name with the origin on it twice' ) or diag $zone;
};

subtest 'a domain that serves neither gets neither name' => sub {
    my $zone = zone_for('plain.test');
    ok( defined $zone, 'a zone was written' ) or return;

    # www and mail were pushed onto every domain here, in a second copy of the
    # list bin/new_config kept.
    unlike( $zone, qr/^www[.]plain[.]test/m,  'no www for a domain running no web server' ) or diag $zone;
    unlike( $zone, qr/^mail[.]plain[.]test/m, 'and no mail for one running no mail' )       or diag $zone;

    # It still has a zone: the apex, its nameserver and the address the pool
    # assigned it.
    like( $zone, qr/^\$ORIGIN\s+plain[.]test\./m,     'while the zone itself is still written' );
    like( $zone, qr/^\@\s+IN\s+A\s+192\.168\.1\.61/m, 'with the address the pool gives it' );
};

subtest 'a record points only at a name that domain has' => sub {

    # The MX and the SRVs name mail.<domain>, so they belong to a zone whose
    # domain serves mail and to no other.  This knows which those are because it
    # reads each domain's recipes -- the same answer it builds the names from.
    my $without = zone_for('plain.test');
    unlike( $without, qr/IN\s+MX\s/,  'no MX where nothing serves mail' ) or diag $without;
    unlike( $without, qr/IN\s+SRV\s/, 'nor the mail SRVs' )               or diag $without;

    my $with = zone_for('post.test');
    ok( defined $with, 'a zone was written for the domain that does' ) or return;

    like( $with, qr/IN\s+MX\s+10\s+mail[.]post[.]test\./, 'the MX is there where mail is served' ) or diag $with;
    like( $with, qr/^_imaps\._tcp\s+IN\s+SRV/m,           'with the SRVs beside it' )              or diag $with;

    # And the name it points at is one the zone actually carries, which is the
    # whole of why these two travel together.
    like( $with, qr/^mail[.]post[.]test\.\s+IN\s+CNAME\s+\@/m, 'and mail. is a name in the zone, not a dangling target' )
      or diag $with;
};

subtest 'a domain the pool has no address for is refused' => sub {
    my $out = tempdir( CLEANUP => 1 );

    my $err = exception {
        capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--ipmap', $ipmap_file, '--output-dir', $out, 'nowhere.test' ) }
    };

    like( $err, qr/No[ ]address[ ]for[ ]'nowhere[.]test'/, 'naming what it has no address for says so' );
    like( $err, qr/ips[.]db/,                              'and says where it looked for one' );
};

done_testing();
