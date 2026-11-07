package Trog::Test::Store;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

use Trog::Config();
use Trog::Credentials();
use Trog::Secrets();

=head1 NAME

Trog::Test::Store - a throwaway secret store, for a test that runs
F<bin/new_config> to the end

=head1 SYNOPSIS

    BEGIN { $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
    use Trog::Test::Store();
    Trog::Test::Store::throwaway();

=head1 DESCRIPTION

Every guest has a file from the secret store, the ssh host key that
L<Provisioner::Recipe::sshd> places.  So every run of F<bin/new_config> opens
the store.  That needs a store, and its password handed in up front, as
L<Trog::Credentials> documents for a run with nobody at a keyboard.

=head1 FUNCTIONS

=head2 $file = throwaway()

Makes a store at F<secrets.kdbx> in the configuration directory of the test,
with the password C<throwaway>, and hands that password to
L<Trog::Credentials>.  Returns the path of the store.  The test sets
C<TROG_PROVISIONER_CONFIG> to a directory of its own first.

=cut

sub throwaway {
    my $file = Trog::Config->path('secrets.kdbx');
    Trog::Secrets->create( $file, 'throwaway', 'secret:seed/entry/password' => 'throwaway' );
    Trog::Credentials->remember( keepass => 'throwaway' );
    return $file;
}

1;
