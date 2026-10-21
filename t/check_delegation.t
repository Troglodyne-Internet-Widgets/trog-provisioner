#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/check_delegation.t - bin/check_delegation: whether a zone is delegated to the nameservers that hold it here

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use YAML::XS();
use Net::DNS();

use FindBin;
use FindBin::libs;

# Never the configuration of the installation.
## no critic (CompileTime) -- setting it at compile time is the point
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns

my $script = "$FindBin::Bin/../bin/check_delegation";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $ZONE = 'customer.test';

my $rfile = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
File::Slurper::Temp::write_text(
    $rfile,
    YAML::XS::Dump(
        {
            _base => {
                _global   => { nameservers => { ns2 => 'NS2.other.test.' } },
                registrar => {
                    accounts => {
                        ours   => { authority => 'ns.ours.test', zones => [$ZONE] },
                        hosted => { type      => 'easydns',      zones => ['hosted.test'] },
                    },
                },
            },
        }
    )
);

# Runs the check with the DNS answering as packets that a nameserver would
# send: for each asked server, a map of "name type" to the answer records and
# whether it has authority.  Returns what main returned, and what it printed.
sub check_against {
    my ( $servers, @args ) = @_;
    my %servers = %{$servers};

    my $mock = Test::MockModule->new('Net::DNS::Resolver::Base');
    $mock->redefine(
        send => sub {
            my ( $self, $name, $type ) = @_;
            my ($server) = $self->nameservers;
            my $said     = ( $servers{$server} // {} )->{"$name $type"} // return;
            my $packet   = Net::DNS::Packet->new( $name, $type );
            $packet->push( answer => map { Net::DNS::RR->new($_) } @{ $said->{answer} } );
            $packet->header->aa( $said->{aa} ? 1 : 0 );
            return $packet;
        }
    );

    my $rc;
    my ($out) = capture { $rc = Provisioner::Bin::check_delegation::main( '--recipes', $rfile, @args ) };
    return ( $rc, $out );
}

my %public = (
    "$ZONE NS"           => { answer => [ "$ZONE NS ns1.ns.ours.test.", "$ZONE NS ns2.other.test." ] },
    'ns1.ns.ours.test A' => { answer => ['ns1.ns.ours.test A 192.0.2.53'] },
    'ns2.other.test A'   => { answer => ['ns2.other.test A 198.51.100.53'] },
);
my $soa = { answer => ["$ZONE SOA ns1.ns.ours.test. hostmaster.ours.test. 1 300 300 1209600 10800"], aa => 1 };

subtest 'a zone delegated to exactly the nameservers that hold it here passes' => sub {
    my %held = ( '192.0.2.53' => { "$ZONE SOA" => $soa }, '198.51.100.53' => { "$ZONE SOA" => $soa } );
    my ( $rc, $out ) = check_against( { '1.1.1.1' => \%public, %held }, $ZONE );
    is( $rc, 0, 'it exits 0' ) or diag $out;
    like( $out, qr/^[ ]{4}ns1[.]ns[.]ours[.]test$/m,           'it expects ns1 of the authority' );
    like( $out, qr/^[ ]{4}ns2[.]other[.]test$/m,               'and the nameservers of _global, in the form that DNS compares' );
    like( $out, qr/ns1[.]ns[.]ours[.]test[ ]answers[ ]for[ ]/, 'and it asked each of them' );
    like( $out, qr/\Q$ZONE\E[ ]is[ ]delegated[ ]here[.]/,      'and says so' );
};

subtest 'a delegation that names another nameserver, or none, fails and says what it found' => sub {
    my %stray = ( %public, "$ZONE NS" => { answer => [ "$ZONE NS ns1.ns.ours.test.", "$ZONE NS ns2.other.test.", "$ZONE NS dns1.registrar.test." ] } );
    my %held  = ( '192.0.2.53' => { "$ZONE SOA" => $soa }, '198.51.100.53' => { "$ZONE SOA" => $soa } );
    my ( $rc, $out ) = check_against( { '1.1.1.1' => \%stray, %held }, $ZONE );
    is( $rc, 1, 'a stray nameserver fails' );
    like( $out, qr/^[ ]{4}dns1[.]registrar[.]test$/m,       'and is named' );
    like( $out, qr/not[ ]delegated[ ]to[ ]exactly[ ]these/, 'with what to do' );

    my %none = %public;
    delete $none{"$ZONE NS"};
    ( $rc, $out ) = check_against( { '1.1.1.1' => \%none, %held }, $ZONE );
    is( $rc, 1, 'and so does no delegation at all' );
    like( $out, qr/no[ ]NS[ ]records/, 'which it says' );
};

subtest 'a nameserver that does not hold the zone fails, with the reason' => sub {
    my ( $rc, $out ) = check_against( { '1.1.1.1' => \%public, '192.0.2.53' => { "$ZONE SOA" => { %$soa, aa => 0 } }, '198.51.100.53' => {} }, $ZONE );
    is( $rc, 1, 'it fails' );
    like( $out, qr/ns1[.]ns[.]ours[.]test[ ]at[ ]192[.]0[.]2[.]53[ ]/,            'an answer' );
    like( $out, qr/but[ ]without[ ]authority/,                                    'without authority is no delegation' );
    like( $out, qr/ns2[.]other[.]test[ ]at[ ]198[.]51[.]100[.]53[ ]did[ ]not[ ]/, 'and nor is no answer' );
};

subtest 'a zone that no account with an authority lists is refused' => sub {
    my $refused = qr/names[ ]an[ ]authority[ ]for[ ]/;
    like( exception { check_against( {}, 'hosted.test' ) },  qr/${refused}hosted[.]test/,  'a zone of a registrar is not ours to answer for' );
    like( exception { check_against( {}, 'nowhere.test' ) }, qr/${refused}nowhere[.]test/, 'and nor is a zone of no account' );
};

done_testing();
