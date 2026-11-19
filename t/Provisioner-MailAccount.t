#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-MailAccount.t - check_name: which names of a mail account are refused

=cut

use Test::More;
use Test::Fatal qw{exception};

use FindBin::libs;

use_ok('Provisioner::MailAccount') or BAIL_OUT('Provisioner::MailAccount does not load');

# The home of an account is /mail/$domain/$name, so a name that is a path
# component with a meaning of its own must be refused whole.
subtest 'check_name refuses the names of the current and the parent directory' => sub {
    foreach my $name ( q{.}, q{..} ) {
        my $err = exception { Provisioner::MailAccount::check_name($name) };
        like( $err, qr/not[ ]'\Q$name\E'[.]\n\z/, "'$name' is refused, and the message names it" );
    }
};

subtest 'check_name returns 1 for a name that is a safe path component' => sub {
    foreach my $name (qw{someone a.b .a a..b a. a+b a-b a_b A1}) {
        is( exception { is( Provisioner::MailAccount::check_name($name), 1, "'$name' passes" ) }, undef, "and '$name' does not die" );
    }
};

subtest 'check_name still refuses what the character class refuses' => sub {
    foreach my $name ( q{}, 'a/b', 'a:b', 'a b', "a\n" ) {
        like( exception { Provisioner::MailAccount::check_name($name) }, qr/not[ ]'/, 'a name that holds a character outside the class is refused' );
    }
};

done_testing();
