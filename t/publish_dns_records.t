#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/publish_dns_records.t - scripts/publish_dns_records: what it sends a provider,
and what it leaves alone

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use Cpanel::JSON::XS ();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/publish_dns_records";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN  = 'guest.test.test';
my $ADDRESS = '192.0.2.50';

# A real executable, because the script refuses to run without one: the shortcut
# is what carries the credential, and its absence is a configuration fault
# rather than something to paper over.
my $dir      = tempdir( CLEANUP => 1 );
my $shortcut = "$dir/$DOMAIN";
open my $fh, '>', $shortcut or BAIL_OUT("Cannot write $shortcut: $!");
print {$fh} "#!/bin/sh\n";
close $fh or BAIL_OUT("Cannot close $shortcut: $!");
chmod 0755, $shortcut or BAIL_OUT("Cannot chmod $shortcut: $!");

sub as_json {
    my (@rows) = @_;

    return Cpanel::JSON::XS->new->encode( \@rows );
}

# The provider, as the one thing the script reaches outside itself with.
#
# The mock lives for as long as the body runs and no longer, which is why this
# takes one rather than handing a guard back: a guard returned and never touched
# again is a lexical every reader has to know is load-bearing.
#
# no_auto, because this package lives inside scripts/publish_dns_records rather
# than in a module of its own -- Test::MockModule otherwise tries to require a
# Trog/PublishDNSRecords.pm that was never going to be there.
sub against {
    my ( $handler, $body ) = @_;

    my @ran;
    my $mock = Test::MockModule->new( 'Trog::PublishDNSRecords', no_auto => 1 );
    $mock->redefine( shortcut_for => sub { return $shortcut } );
    $mock->redefine(
        run => sub {
            my ($command) = @_;
            push @ran, $command;
            return $handler->($command);
        }
    );

    $body->( \@ran );

    return;
}

# A provider holding exactly these rows, and accepting whatever is sent to it.
sub holding {
    my (@rows) = @_;

    return sub {
        my ($command) = @_;
        return ( as_json(@rows), 1 ) if index( $command, ' list ' ) >= 0;
        return ( q{},            1 );
    };
}

sub sent {
    my ( $ran, $action ) = @_;

    return grep { index( $_, " $action " ) >= 0 } @{$ran};
}

subtest 'a record the provider does not hold is created' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my ($create) = sent( $ran, 'create' );
            ok( $create, 'a create was sent' ) or return;
            like( $create, qr/[ ]create[ ]A[ ]/,         'for an A record' );
            like( $create, qr/--name='\Q$DOMAIN\E'/,     'named for the domain' );
            like( $create, qr/--content='\Q$ADDRESS\E'/, 'carrying the address the guest was built with' );
            unlike( $create, qr/--identifier/, 'and no identifier, there being no record of theirs to amend' );

            is( scalar sent( $ran, 'delete' ), 0, 'nothing is deleted, the zone being somebody else to keep' );

            # A type with nothing wanted of it is not asked about at all: a
            # domain with no aliases has no CNAME to publish, and the list that
            # would have found that out is a round trip for an empty answer.
            my @lists = grep { index( $_, ' list ' ) >= 0 } @{$ran};
            is( scalar @lists, 1, 'and with no aliases the provider is asked for A alone' );
        }
    );
};

subtest 'a record holding the wrong address is updated through its identifier' => sub {
    against(
        holding( { name => $DOMAIN, type => 'A', content => '10.0.0.9', id => 'the-id', ttl => 300 } ),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my ($update) = sent( $ran, 'update' );
            ok( $update, 'an update was sent rather than a second create' ) or return;

            # The identifier is how a provider is told which of its records to
            # amend.  Without it the update either fails or lands on whichever
            # record the provider picks, which is not a thing to leave to chance
            # in a zone holding records this knows nothing about.
            like( $update, qr/--identifier='the-id'/,    'naming the record the provider gave back' );
            like( $update, qr/--content='\Q$ADDRESS\E'/, 'with the address it should have had' );
            is( scalar sent( $ran, 'create' ), 0, 'and nothing is created alongside it' );
        }
    );
};

subtest 'a record that is already right is left entirely alone' => sub {
    against(
        holding( { name => $DOMAIN, type => 'A', content => $ADDRESS, id => 'the-id', ttl => 300 } ),
        sub {
            my ($ran) = @_;

            my ($said) = capture { Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) };
            is( scalar sent( $ran, 'create' ), 0, 'nothing is created' );
            is( scalar sent( $ran, 'update' ), 0, 'and nothing is rewritten with what it already says' );
            like( $said, qr/already/, 'and it says so' );
        }
    );
};

subtest 'each alias becomes a CNAME at the name that holds the address' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS, "mail.$DOMAIN", "www.$DOMAIN" ) };
            is( $rc, 0, 'the run succeeds' );

            my @cnames = grep { index( $_, ' CNAME ' ) >= 0 } sent( $ran, 'create' );
            is( scalar @cnames, 2, 'one per alias' );
            like( $cnames[0], qr/--name='mail[.]\Q$DOMAIN\E'/, 'sorted, so a rebuild sends them in the same order' );
            like( $cnames[0], qr/--content='\Q$DOMAIN\E'/,     'pointing at the domain itself' );

            # ns1 is pdns's to publish: a guest serving its own zone is its own
            # nameserver, and a zone a registrar holds has nameservers of theirs.
            is( scalar grep( { index( $_, 'ns1' ) >= 0 } @{$ran} ), 0, 'and no ns1 is claimed' );

            # Once per type, not once per record.  Every list is a round trip to
            # whoever holds the zone, and asking again between two aliases
            # decides about them against two different answers.
            my @lists = grep { index( $_, ' list ' ) >= 0 } @{$ran};
            is( scalar @lists, 2, 'the provider was asked once for A and once for CNAME, however many aliases there are' );
        }
    );
};

subtest 'a provider that cannot be asked stops the run rather than publishing over it' => sub {
    against(
        sub { return ( 'the provider said no', 0 ) },
        sub {
            my ($ran) = @_;

            # An empty list and a question that failed look the same to anything
            # that does not check: both read as a zone with no records, and the
            # difference is whether creating one is right.
            like(
                exception {
                    capture { Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) }
                },
                qr/Could[ ]not[ ]ask[ ]the[ ]provider/,
                'it says it could not ask'
            );
            is( scalar sent( $ran, 'create' ), 0, 'and creates nothing on the strength of an answer it did not get' );
        }
    );
};

subtest 'an answer that is not JSON is not an empty zone either' => sub {
    against(
        sub { return ( 'Traceback (most recent call last):', 1 ) },
        sub {
            my ($ran) = @_;

            like(
                exception {
                    capture { Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) }
                },
                qr/not[ ]JSON/,
                'it says what it got instead'
            );
            is( scalar sent( $ran, 'create' ), 0, 'and publishes nothing' );
        }
    );
};

subtest 'a record the provider refuses is reported without taking the rest down' => sub {
    against(
        sub {
            my ($command) = @_;
            return ( as_json(), 1 ) if index( $command, ' list ' ) >= 0;
            return ( 'refused', 0 ) if index( $command, ' A ' ) >= 0;
            return ( q{},       1 );
        },
        sub {
            my ($ran) = @_;

            my $rc;
            my ( undef, $complaint ) = capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS, "www.$DOMAIN" ) };

            isnt( $rc, 0, 'the run reports a failure' );
            like( $complaint, qr/Could[ ]not[ ]publish/, 'naming what would not go' );
            ok( scalar( grep { index( $_, ' CNAME ' ) >= 0 } @{$ran} ), 'while the rest of the records were still attempted' );
        }
    );
};

subtest 'a dry run says what it would send and sends none of it' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my ($said) = capture { Trog::PublishDNSRecords::main( '--dryrun', $DOMAIN, $ADDRESS ) };

            like( $said, qr/DRY[ ]RUN/, 'it says so' );
            is( scalar sent( $ran, 'create' ), 0, 'and nothing was sent' );
        }
    );
};

subtest 'without the shortcut there is no credential, and it says so' => sub {
    my $mock = Test::MockModule->new( 'Trog::PublishDNSRecords', no_auto => 1 );
    $mock->redefine( shortcut_for => sub { return "$dir/nothing-is-here" } );

    like(
        exception { Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) },
        qr/No[ ]lexicon[ ]shortcut/,
        'naming the file it wanted'
    );
};

done_testing();
