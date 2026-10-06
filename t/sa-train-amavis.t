#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/sa-train-amavis.t - scripts/sa_train_amavis: which mail trains amavis as spam, which as ham, and who owns the database afterwards

=cut

use Test::More;
use File::Path    qw{make_path};
use File::Temp    qw{tempdir};
use File::Slurper qw{read_lines};
use File::Slurper::Temp();
use IPC::Run3();
use Time::HiRes();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/sa_train_amavis";

# sa-learn and chown that write down how they were called, one line a call, and
# change nothing.  First on PATH, so the script finds them and not the real ones.
my $bin = tempdir( CLEANUP => 1 );
my $log = "$bin/calls";
foreach my $fake (qw{sa-learn chown}) {
    File::Slurper::Temp::write_text( "$bin/$fake", qq{#!/bin/sh\necho "$fake \$*" >> '$log'\n} );
    chmod 0755, "$bin/$fake" or die "chmod $bin/$fake: $!";
}

sub train {
    my (@maildirs) = @_;
    unlink $log;
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    IPC::Run3::run3( [ $script, @maildirs ], \undef, \my $out, \my $err );
    my @calls = -e $log ? read_lines($log) : ();
    return { rc => $? >> 8, err => $err // q{}, calls => \@calls };
}

# A message as dovecot stores it: the flags after :2, in the name, and the
# date that it arrived as the mtime.
sub message {
    my ( $dir, $name, $days_old ) = @_;
    make_path($dir);
    File::Slurper::Temp::write_text( "$dir/$name", "Subject: x\n\nbody\n" );
    my $when = Time::HiRes::time() - $days_old * 86_400;
    utime $when, $when, "$dir/$name" or die "utime $dir/$name: $!";
    return "$dir/$name";
}

subtest 'spam is the Junk folder, ham is old read mail in the INBOX' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    message( "$maildir/.Junk/cur", '1.junk:2,S',      1 );
    message( "$maildir/.Junk/new", '1.unopened-junk', 1 );
    my $old_read   = message( "$maildir/cur", '2.old-read:2,S',     30 );
    my $old_flags  = message( "$maildir/cur", '3.old-replied:2,RS', 30 );
    my $old_unread = message( "$maildir/cur", '4.old-unread:2,',    30 );
    my $new_read   = message( "$maildir/cur", '5.new-read:2,S',     1 );

    my $r = train($maildir);
    is( $r->{rc}, 0, 'it succeeds' ) or diag $r->{err};

    my $spam = join "\n", grep { m/--spam/ } @{ $r->{calls} };
    like( $spam, qr{\Q$maildir\E/[.]Junk/cur$}m, 'the Junk folder is learned as spam' )                            or diag explain $r->{calls};
    like( $spam, qr{\Q$maildir\E/[.]Junk/new$}m, 'including spam that nobody opened, which dovecot keeps in new' ) or diag explain $r->{calls};

    my $ham = join "\n", grep { m/--ham/ } @{ $r->{calls} };
    like( $ham, qr{\Q$old_read\E},  'mail that was read a month ago is ham' );
    like( $ham, qr{\Q$old_flags\E}, 'and so is mail with other flags beside the read one' );
    unlike( $ham, qr{\Q$old_unread\E}, 'mail that nobody has read is not, however old it is' );
    unlike( $ham, qr{\Q$new_read\E},   'nor is read mail from this week, which can still go to Junk' );
};

subtest 'every learn writes to the database of amavis, which gets it back' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    message( "$maildir/.Junk/cur", '1.junk:2,S',     1 );
    message( "$maildir/cur",       '2.old-read:2,S', 30 );

    my @calls  = @{ train($maildir)->{calls} };
    my @learns = grep { m/^sa-learn/ } @calls;
    is( scalar( grep { m{--dbpath[ ]/var/lib/amavis/\.spamassassin[ ]} } @learns ), scalar @learns, 'each sa-learn names the database that amavis reads' )
      or diag explain \@learns;
    like( $calls[-2], qr/^sa-learn .*--sync/, 'the journal is synced into the database once, after the learning' ) or diag explain \@calls;
    is( $calls[-1], 'chown -R amavis:amavis /var/lib/amavis/.spamassassin', 'and amavis owns the database again at the end' );
};

subtest 'an account with no mail yet is not an error' => sub {
    my $empty = tempdir( CLEANUP => 1 ) . '/Maildir';
    my $r     = train($empty);
    is( $r->{rc},                                            0, 'it succeeds' )        or diag $r->{err};
    is( scalar( grep { m/--spam|--ham/ } @{ $r->{calls} } ), 0, 'and learns nothing' ) or diag explain $r->{calls};
    is( $r->{calls}[-1],                                     'chown -R amavis:amavis /var/lib/amavis/.spamassassin', 'but still gives the database back' );
};

done_testing();
