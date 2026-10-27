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
use List::Util       ();
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
# A list names a type, and gets the rows of that type.
sub holding {
    my (@rows) = @_;

    return sub {
        my ($command) = @_;
        my ($type)    = $command =~ m/[ ]list[ ](\S+)[ ]/;
        return ( as_json( grep { $_->{type} eq $type } @rows ), 1 ) if defined $type;
        return ( q{},                                           1 );
    };
}

# Whether one line of what the run sent is a call of $action.
sub is_action {
    my ( $line, $action ) = @_;
    return index( $line, " $action " ) >= 0;
}

sub sent {
    my ( $ran, $action ) = @_;

    return grep { is_action( $_, $action ) } @{$ran};
}

# The first call of $action that the run sent.
sub first_sent {
    my ( $ran, $action ) = @_;

    return List::Util::first { is_action( $_, $action ) } @{$ran};
}

subtest 'a record the provider does not hold is created' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my $create = first_sent( $ran, 'create' );
            ok( $create, 'a create was sent' ) or return;
            like( $create, qr/[ ]create[ ]A[ ]/,         'for an A record' );
            like( $create, qr/--name='\Q$DOMAIN\E'/,     'named for the domain' );
            like( $create, qr/--content='\Q$ADDRESS\E'/, 'carrying the address the guest was built with' );
            unlike( $create, qr/--identifier/, 'and no identifier, there being no record of theirs to amend' );

            is( scalar sent( $ran, 'delete' ), 0, 'nothing is deleted, the zone being somebody else to keep' );

            # The CNAMEs are asked about with no alias to publish, because a
            # CNAME at the domain would leave no room for its A record.
            my @lists = grep { index( $_, ' list ' ) >= 0 } @{$ran};
            is( scalar @lists, 2, 'and the provider is asked once for A and once for CNAME' );
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

            my $update = first_sent( $ran, 'update' );
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

            # A zone a registrar holds has nameservers of theirs.
            is( scalar grep( { index( $_, 'ns1' ) >= 0 } @{$ran} ), 0, 'and no ns1 is claimed unless one is named' );

            # Once per type, not once per record.  Every list is a round trip to
            # whoever holds the zone, and asking again between two aliases
            # decides about them against two different answers.
            my @lists = grep { index( $_, ' list ' ) >= 0 } @{$ran};
            is( scalar @lists, 2, 'the provider was asked once for A and once for CNAME, however many aliases there are' );
        }
    );
};

subtest 'each addressed name gets the address of the domain, as an A record' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--addressed', "ns1.$DOMAIN", '--addressed', "mail.$DOMAIN", $DOMAIN, $ADDRESS, "www.$DOMAIN" ) };
            is( $rc, 0, 'the run succeeds' );

            foreach my $name ( "ns1.$DOMAIN", "mail.$DOMAIN" ) {
                my ($made) = grep { index( $_, "--name='$name'" ) >= 0 } sent( $ran, 'create' );
                ok( $made, "$name is created" ) or diag join "\n", @{$ran};
                like( $made // q{}, qr/[ ]A[ ]/,                  'as an A record, because the target of an NS, an MX or an SRV must not be a CNAME' );
                like( $made // q{}, qr/--content='\Q$ADDRESS\E'/, 'at the address of the domain' );
            }
        }
    );

    like( exception { Trog::PublishDNSRecords::main( '--delegate', '--shortcut', $shortcut, '--addressed', "ns1.$DOMAIN", $DOMAIN, "ns1.$DOMAIN" ) }, qr/usage/, 'a delegation names its nameserver as an argument, not with the option' );
};

subtest 'an alias of the domain at an addressed name is replaced by the address' => sub {
    my @alias = ( { name => "mail.$DOMAIN", type => 'CNAME', content => "$DOMAIN.", id => 'the-alias' } );
    against(
        holding(@alias),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--addressed', "mail.$DOMAIN", $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my $delete = first_sent( $ran, 'delete' );
            like( $delete // q{}, qr/[ ]delete[ ]CNAME[ ]--name='mail[.]\Q$DOMAIN\E'/, 'the CNAME that an earlier build published is deleted' );
            like( $delete // q{}, qr/--identifier='the-alias'/,                        'through the identifier that the provider gave it' );
            my ($made) = grep { index( $_, "--name='mail.$DOMAIN'" ) >= 0 } sent( $ran, 'create' );
            like( $made // q{}, qr/[ ]create[ ]A[ ]/, 'and the A record is created' ) or diag join "\n", @{$ran};
            my $order = List::Util::first { index( $ran->[$_], ' delete ' ) >= 0 || index( $ran->[$_], "create A --name='mail." ) >= 0 } 0 .. $#{$ran};
            like( $ran->[ $order // 0 ], qr/[ ]delete[ ]/, 'after the CNAME is gone, because a name with a CNAME holds no other record' );
        }
    );

    against(
        holding(@alias),
        sub {
            my ($ran) = @_;
            capture { Trog::PublishDNSRecords::main( '--dryrun', '--addressed', "mail.$DOMAIN", $DOMAIN, $ADDRESS ) };
            is( scalar sent( $ran, 'delete' ), 0, 'a dry run deletes nothing' );
        }
    );

    against(
        sub {
            my ($command) = @_;
            return holding(@alias)->($command) if index( $command, ' list ' ) >= 0;
            return ( 'refused', 0 ) if index( $command, ' delete ' ) >= 0;
            return ( q{}, 1 );
        },
        sub {
            my ($ran) = @_;
            my $rc;
            my ( undef, $said ) = capture { $rc = Trog::PublishDNSRecords::main( '--addressed', "mail.$DOMAIN", $DOMAIN, $ADDRESS ) };
            is( $rc, 1, 'a delete that the provider refuses fails the run' );
            like( $said, qr/Could[ ]not[ ]delete[ ]CNAME[ ]mail/, 'and says so' );
            is( scalar grep( { index( $_, "--name='mail." ) >= 0 } sent( $ran, 'create' ) ), 0, 'and no A record is sent beside the CNAME' );
        }
    );

    against(
        holding( { name => "mail.$DOMAIN", type => 'CNAME', content => 'elsewhere.test', id => 'theirs' } ),
        sub {
            my ($ran) = @_;
            my $rc;
            my ( undef, $said ) = capture { $rc = Trog::PublishDNSRecords::main( '--addressed', "mail.$DOMAIN", $DOMAIN, $ADDRESS ) };
            is( $rc, 1, 'a CNAME of another name is refused' );
            like( $said, qr/Refusing[ ]to[ ]publish[ ]A[ ]mail/, 'and named' );
            is( scalar sent( $ran, 'delete' ), 0, 'and kept' );
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

subtest 'a delegation goes to the zone above, through the shortcut it is given' => sub {
    my $zone = "lab.$DOMAIN";
    my $ns   = "ns.$zone";

    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--delegate', '--shortcut', $shortcut, $zone, $ns, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my @made = sent( $ran, 'create' );
            is( scalar @made, 2, 'two records are sent' );
            my ($ns_record) = grep { index( $_, ' NS ' ) >= 0 } @made;
            like( $ns_record, qr/--name='\Q$zone\E'[ ]--content='\Q$ns\E[.]'/, 'the NS of the zone, naming its nameserver with its trailing dot, which PowerDNS wants' );
            my ($glue) = grep { index( $_, ' A ' ) >= 0 } @made;
            like( $glue,    qr/--name='\Q$ns\E'[ ]--content='\Q$ADDRESS\E'/, 'and the address of the nameserver, which is inside the zone' );
            like( $made[0], qr/\A'\Q$shortcut\E'/,                           'through the shortcut on the command line' );
        }
    );

    against(
        holding( { name => "$zone.", type => 'NS', content => "\U$ns.", id => 'the-id' } ),
        sub {
            my ($ran) = @_;
            capture { Trog::PublishDNSRecords::main( '--delegate', '--shortcut', $shortcut, $zone, $ns ) };
            is( scalar sent( $ran, 'create' ) + scalar sent( $ran, 'update' ), 0, 'a provider that answers with a trailing dot and in capitals already holds it, and there is no address to send' );
        }
    );

    like( exception { Trog::PublishDNSRecords::main( '--delegate', $zone, $ns ) },                                qr/usage/, 'a delegation names its shortcut, because the zone above is not the zone of a domain here' );
    like( exception { Trog::PublishDNSRecords::main( '--delegate', '--shortcut', $shortcut, $zone ) },            qr/usage/, 'and its nameserver' );
    like( exception { Trog::PublishDNSRecords::main( '--delegate', '--shortcut', $shortcut, $zone, $ns, 1, 2 ) }, qr/usage/, 'and one address at most' );
};

subtest 'names of another zone become CNAMEs of a target outside it, and nothing else' => sub {
    against(
        holding(),
        sub {
            my ($ran) = @_;

            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--shortcut', $shortcut, '--alias-of', $DOMAIN, 'www.partner.test', 'shop.partner.test' ) };
            is( $rc, 0, 'the run succeeds' );

            my @creates = sent( $ran, 'create' );
            is( scalar @creates, 2, 'one record per name' );
            my $cname = qr/[ ]create[ ]CNAME[ ]/;
            like( $creates[0], qr/$cname--name='shop[.]partner[.]test'[ ]/, 'each a CNAME' );
            like( $creates[0], qr/--content='\Q$DOMAIN\E[.]'/,              'of the target, absolute, so that lexicon does not qualify it into the zone' );
            is( scalar grep( { index( $_, ' create A ' ) >= 0 } @creates ), 0, 'and no A record, because the target holds its address in its own zone' );
        }
    );

    like( exception { Trog::PublishDNSRecords::main( '--alias-of', $DOMAIN, 'www.partner.test' ) },                           qr/usage/, 'the names are of another zone, so they need its shortcut' );
    like( exception { Trog::PublishDNSRecords::main( '--shortcut', $shortcut, '--alias-of', $DOMAIN ) },                      qr/usage/, 'and at least one name' );
    like( exception { Trog::PublishDNSRecords::main( '--shortcut', $shortcut, '--alias-of', $DOMAIN, qw{--delegate z ns} ) }, qr/usage/, 'and not a delegation as well' );
};

subtest 'a name that holds a CNAME gets no other record, and one that holds an A record gets no CNAME' => sub {
    against(
        holding( { name => $DOMAIN, type => 'CNAME', content => 'elsewhere.test', id => 'c' }, { name => "www.$DOMAIN", type => 'A', content => '10.0.0.9', id => 'a' } ),
        sub {
            my ($ran) = @_;

            my ( $rc, $said );
            ( undef, $said ) = capture { $rc = Trog::PublishDNSRecords::main( $DOMAIN, $ADDRESS, "www.$DOMAIN", "mail.$DOMAIN" ) };
            is( $rc, 1, 'the run fails, so the build stops' );
            my $refused = qr/Refusing[ ]to[ ]publish[ ]/;
            like( $said, qr/${refused}A[ ]\Q$DOMAIN\E:[ ].*CNAME[ ]elsewhere/,   'an A record beside a CNAME is refused, naming the CNAME' );
            like( $said, qr/${refused}CNAME[ ]www[.]\Q$DOMAIN\E:[ ].*A[ ]10[.]/, 'and a CNAME beside an A record, naming the A record' );

            is( scalar grep( { index( $_, $ADDRESS ) >= 0 || index( $_, "--name='www." ) >= 0 } sent( $ran, 'create' ), sent( $ran, 'update' ) ), 0, 'neither is sent' );
            ok( ( grep { index( $_, "--name='mail.$DOMAIN'" ) >= 0 } sent( $ran, 'create' ) ), 'and a name with no clash is still published' );
        }
    );
};

# A records file, as Provisioner::Recipe::registrar writes it.
sub records_file {
    my (@records) = @_;
    my $file = "$dir/records.json";
    open my $out, '>', $file or BAIL_OUT("Cannot write $file: $!");
    print {$out} Cpanel::JSON::XS->new->encode( \@records );
    close $out or BAIL_OUT("Cannot close $file: $!");
    return $file;
}

my %MX  = ( type => 'MX',  name => $DOMAIN, content => "10 mail.$DOMAIN." );
my %SPF = ( type => 'TXT', name => $DOMAIN, content => 'v=spf1 +a +mx -all', match => 'v=spf1' );
my %SRV = ( type => 'SRV', name => "_imaps._tcp.$DOMAIN", content => "0 0 993 mail.$DOMAIN.", match => q{} );

subtest 'each record of the file goes up beside the names' => sub {
    my $file = records_file( \%MX, \%SPF, \%SRV );
    against(
        holding(),
        sub {
            my ($ran) = @_;
            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds' );

            my @made = sent( $ran, 'create' );
            my $mx   = qr/--content='10[ ]mail[.]\Q$DOMAIN\E[.]'/;
            ok( ( grep { m/[ ]create[ ]MX[ ]--name='\Q$DOMAIN\E'[ ]$mx/ } @made ),                  'the MX, with its priority in the content' ) or diag join "\n", @made;
            ok( ( grep { m/[ ]create[ ]TXT[ ].*--content='v=spf1[ ][+]a[ ][+]mx[ ]-all'/ } @made ), 'the TXT, with its spaces in one argument' ) or diag join "\n", @made;
            ok( ( grep { m/[ ]create[ ]SRV[ ]--name='_imaps[.]_tcp[.]/ } @made ),                   'and the SRV' )                              or diag join "\n", @made;
            ok( ( grep { m/[ ]create[ ]A[ ]/ } @made ),                                             'and the A record of the domain still' );
        }
    );
};

subtest 'a TXT record with a match replaces only the record that it matches' => sub {
    my $file = records_file( \%SPF );
    my @apex = (
        { name => $DOMAIN, type => 'TXT', content => 'google-site-verification=xyz', id => 'theirs' },
        { name => $DOMAIN, type => 'TXT', content => '"v=spf1 -all"',                id => 'ours' },
    );
    against(
        holding(@apex),
        sub {
            my ($ran) = @_;
            capture { Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) };
            my ($update) = grep { index( $_, ' TXT ' ) >= 0 } sent( $ran, 'update' );
            like( $update // q{}, qr/--identifier='ours'/, 'the SPF that is there is updated, through its identifier' );
            is( scalar grep( { index( $_, 'theirs' ) >= 0 } @{$ran} ),               0, 'and the other TXT record at the apex is left alone' );
            is( scalar grep( { index( $_, ' TXT ' ) >= 0 } sent( $ran, 'create' ) ), 0, 'and no second SPF is created' );
        }
    );

    against(
        holding( { name => $DOMAIN, type => 'TXT', content => '"v=spf1 +a +mx -all"', id => 'ours' } ),
        sub {
            my ($ran)  = @_;
            my ($said) = capture { Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) };
            is( scalar grep( { index( $_, ' TXT ' ) >= 0 } sent( $ran, 'create' ), sent( $ran, 'update' ) ), 0, 'a record that is already right, in quotes, is not sent again' );
            like( $said, qr/TXT[ ]\Q$DOMAIN\E[ ]is[ ]already/, 'and it says so' );
        }
    );
};

subtest 'a record without a match owns only the same content, and an empty match owns the name' => sub {
    my $file = records_file( \%MX, \%SRV );
    against(
        holding(
            { name => $DOMAIN,               type => 'MX',  content => "20 backup.$DOMAIN.",     id => 'backup' },
            { name => "_imaps._tcp.$DOMAIN", type => 'SRV', content => "0 0 9993 mail.$DOMAIN.", id => 'old-srv' },
        ),
        sub {
            my ($ran) = @_;
            capture { Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) };
            is( scalar grep( { index( $_, 'backup' ) >= 0 } @{$ran} ), 0, 'another MX of the domain is left alone' );
            ok( ( grep { index( $_, ' create MX ' ) >= 0 } @{$ran} ), 'and ours is created beside it' );
            like( ( grep { index( $_, ' SRV ' ) >= 0 } sent( $ran, 'update' ) )[0] // q{}, qr/--identifier='old-srv'/, 'the SRV of the name is updated in place' );
        }
    );
};

subtest 'a record at a name that holds a CNAME is refused' => sub {
    my $file = records_file( { type => 'TXT', name => "_dmarc.$DOMAIN", content => 'v=DMARC1; p=none', match => 'v=DMARC1' } );
    against(
        holding( { name => "_dmarc.$DOMAIN", type => 'CNAME', content => 'elsewhere.test', id => 'c' } ),
        sub {
            my ($ran) = @_;
            my $rc;
            my ( undef, $said ) = capture { $rc = Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) };
            is( $rc, 1, 'the run fails' );
            like( $said, qr/Refusing[ ]to[ ]publish[ ]TXT[ ]_dmarc/, 'naming the record' );
            is( scalar grep( { index( $_, ' TXT ' ) >= 0 } sent( $ran, 'create' ) ), 0, 'and sends nothing' );
        }
    );
};

subtest 'a records directory gives the records of every .json file in it' => sub {
    my $records = tempdir( CLEANUP => 1 );
    my $write   = sub {
        my ( $name, $text ) = @_;
        open my $out, '>', "$records/$name" or BAIL_OUT("Cannot write $records/$name: $!");
        print {$out} $text;
        close $out or BAIL_OUT("Cannot close $records/$name: $!");
    };
    $write->( 'registrar.json', Cpanel::JSON::XS->new->encode( [ \%MX ] ) );
    $write->( 'dkim.json',      Cpanel::JSON::XS->new->encode( [ { type => 'TXT', name => "default._domainkey.$DOMAIN", content => 'v=DKIM1; p=KEY', match => 'v=DKIM1' } ] ) );
    $write->( 'notes.txt',      'not records' );

    against(
        holding(),
        sub {
            my ($ran) = @_;
            my $rc;
            capture { $rc = Trog::PublishDNSRecords::main( '--records', $records, $DOMAIN, $ADDRESS ) };
            is( $rc, 0, 'the run succeeds, past a file that is not .json' );
            my @made = sent( $ran, 'create' );
            ok( ( grep { index( $_, ' create MX ' ) >= 0 } @made ),                         'the records of one file go up' );
            ok( ( grep { index( $_, "--name='default._domainkey.$DOMAIN'" ) >= 0 } @made ), 'and those of the other' );
        }
    );

    against(
        holding(),
        sub {
            like(
                exception {
                    capture { Trog::PublishDNSRecords::main( '--records', "$records/nothing-is-here", $DOMAIN, $ADDRESS ) }
                },
                qr/Cannot[ ]read[ ]the[ ]records/,
                'a path that is neither stops the run'
            );
        }
    );
};

subtest 'a records file that is not a list stops the run' => sub {
    my $file = "$dir/broken.json";
    open my $out, '>', $file or BAIL_OUT("Cannot write $file: $!");
    print {$out} '{}';
    close $out or BAIL_OUT("Cannot close $file: $!");
    against(
        holding(),
        sub {
            like(
                exception {
                    capture { Trog::PublishDNSRecords::main( '--records', $file, $DOMAIN, $ADDRESS ) }
                },
                qr/holds[ ]no[ ]list/,
                'naming the file'
            );
        }
    );
    like( exception { Trog::PublishDNSRecords::main( '--records', $file, '--delegate', '--shortcut', $shortcut, 'z.test', 'ns.z.test' ) }, qr/usage/, 'and a delegation takes no records' );
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
