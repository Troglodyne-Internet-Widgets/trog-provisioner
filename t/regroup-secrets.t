#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/regroup-secrets.t - moving the secrets an older Trog::Secrets left in the root
group into the groups their references name

=cut

use Test::More;
use Capture::Tiny qw{capture_stdout};
use File::Temp    qw{tempdir};

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use File::KeePass::KDBX();
use File::Slurper::Temp();

use Provisioner::Cookbook();
use Trog::Credentials();
use Trog::Secrets();

my $script = "$FindBin::Bin/../bin/regroup_secrets";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# One domain, with a note in it.  So this installation asks for the key of that
# guest and for the secret the note names, and nothing else.
File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    "---\n_base:\n  _global:\n    install_dir: /opt/domains\nexample.test:\n  ntp:\n    servers: ['secret:mine/thing/password']\n"
);
Provisioner::Cookbook->forget();
Trog::Credentials->remember( 'keepass', 'pw' );

my $GUEST = 'secret:guests/example.test/password';
my $NOTE  = 'secret:mine/thing/password';

# A store as the older code wrote one: the groups are there, and every entry
# it wrote is in the root group whatever its reference said.
sub store_of_its_time {
    my (%entry_by_title) = @_;

    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    my $kdbx = File::KeePass::KDBX->new;
    $kdbx->add_group( { title => 'Root' } );
    $kdbx->add_group( { title => $_ } ) for qw{guests mine};

    $kdbx->add_entry( { title => $_, password => $entry_by_title{$_} } ) for sort keys %entry_by_title;

    $kdbx->save_db( $file, 'pw' );
    return $file;
}

sub where_things_are {
    my ($file) = @_;

    my $kdbx = File::KeePass::KDBX->load_db( $file, 'pw' );
    $kdbx->unlock;

    my %by_group;
    my $walk;
    $walk = sub {
        my ($groups) = @_;
        foreach my $group ( @{ $groups // [] } ) {
            $by_group{ $group->{title} } = [ sort map { $_->{title} } @{ $group->{entries} // [] } ];
            $walk->( $group->{groups} );
        }
        return;
    };
    $walk->( $kdbx->groups );

    return %by_group;
}

subtest 'an entry in the root group moves to the group its reference names' => sub {
    my $file = store_of_its_time( 'example.test' => 'the guest key', 'thing' => 'the note' );

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::regroup_secrets::main( '--secrets', $file ) };
    is( $rc, 0, 'it has nothing it could not place' );

    my %where = where_things_are($file);
    is_deeply( $where{guests}, ['example.test'], 'the guest key is in guests' );
    is_deeply( $where{mine},   ['thing'],        'and what the note names is in its group' );
    is_deeply( $where{Root},   [],               'with nothing left behind in the root group' );

    like( $said, qr/\Q$GUEST\E/, 'the report names each one it moved' );
    like( $said, qr/\Q$NOTE\E/,  'including the one the configuration asked for' );

    # The point of the move: these are the reads a provision does, and before
    # it they found nothing and generated a new value instead.
    my %held = Trog::Secrets->lookup( $file, 'pw', guest => $GUEST, note => $NOTE );
    is( $held{guest}, 'the guest key', 'and the key reads back where a provision looks for it' );
    is( $held{note},  'the note',      'as does the secret the note names' );
};

subtest 'a dry run says what it would do and writes nothing' => sub {
    my $file   = store_of_its_time( 'example.test' => 'the guest key' );
    my $before = ( stat $file )[7];

    my ($said) = capture_stdout { Provisioner::Bin::regroup_secrets::main( '--secrets', $file, '--dryrun' ) };

    like( $said, qr/nothing[ ]is[ ]written/, 'it says so' );
    like( $said, qr/\Q$GUEST\E/,             'and names what it would move' );

    my %where = where_things_are($file);
    is_deeply( $where{guests}, [],               ' the entry has not moved' );
    is_deeply( $where{Root},   ['example.test'], 'and is where it was' );
    is( ( stat $file )[7], $before, 'the file is the size it was' );
};

subtest 'an entry that is already filed is left alone' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->create( $file, 'pw', $GUEST => 'filed by hand' );

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::regroup_secrets::main( '--secrets', $file ) };
    is( $rc, 0, 'nothing to place' );

    my %held = Trog::Secrets->lookup( $file, 'pw', probe => $GUEST );
    is( $held{probe}, 'filed by hand', 'and its value is untouched' );

    like( $said, qr/Already[ ]in[ ]the[ ]right[ ]group:[ ]1/, 'the report counts it' );
    unlike( $said, qr/Moved[ ]into/, 'and moves nothing' );
};

subtest 'a copy left somewhere else is reported, not moved' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->create( $file, 'pw', $GUEST => 'the one that is read' );

    # The shape a migration by hand leaves: the entry is where the reference
    # says, and an older copy of the same key is still sitting elsewhere.
    my $kdbx = File::KeePass::KDBX->load_db( $file, 'pw' );
    $kdbx->unlock;
    my $old = $kdbx->add_group( { title => 'mine' } );
    $kdbx->add_entry( { group => $old, title => 'example.test', password => 'the older copy' } );
    $kdbx->save_db( $file, 'pw' );

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::regroup_secrets::main( '--secrets', $file ) };
    is( $rc, 0, 'there is nothing it cannot place' );

    like( $said, qr/held[ ]somewhere[ ]else/, 'but it says there is another copy' );
    like( $said, qr/mine/,                    'and where' );
    like( $said, qr/forget_secret/,           'and what removes it' );

    my %where = where_things_are($file);
    is_deeply( $where{mine}, ['example.test'], 'it does not delete anything itself' );

    my %held = Trog::Secrets->lookup( $file, 'pw', probe => $GUEST );
    is( $held{probe}, 'the one that is read', 'and the entry that is read is the one in the named group' );
};

subtest 'two entries of one name are left where they are, and named' => sub {
    my $file = store_of_its_time( 'example.test' => 'one of them' );

    # A second copy somewhere else, which is what a half-finished migration by
    # hand leaves.  Nothing here can tell which one a guest was built with.
    my $kdbx = File::KeePass::KDBX->load_db( $file, 'pw' );
    $kdbx->unlock;
    my ($mine) = grep { $_->{title} eq 'mine' } @{ $kdbx->groups };
    $kdbx->add_entry( { group => $mine, title => 'example.test', password => 'the other' } );
    $kdbx->save_db( $file, 'pw' );

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::regroup_secrets::main( '--secrets', $file ) };
    is( $rc, 1, 'it exits saying something is left to do' );

    like( $said, qr/more[ ]than[ ]one[ ]entry/, 'the report says why it left it' );
    like( $said, qr/\Q$GUEST\E/,                'names the reference' );
    like( $said, qr/mine/,                      'and where the copies are' );

    my %where = where_things_are($file);
    is_deeply( $where{guests}, [], 'and neither copy was moved' );
};

done_testing();
