#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/sa-train-amavis.t - scripts/sa_train_amavis: which folders train amavis as spam, which as ham, and who owns the database afterwards

=cut

use Test::More;
use File::Path    qw{make_path};
use File::Temp    qw{tempdir};
use File::Slurper qw{read_lines};
use File::Slurper::Temp();
use IPC::Run3();

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

# doveconf as it prints a configuration that gives special uses.  The folders
# are not the names that the recipe declares, so a script that knows those names
# by heart fails here.
my $doveconf = <<'CONF';
namespace inbox {
  inbox = yes
  mailbox Bin {
    special_use = \Trash
  }
  mailbox Entwuerfe {
    special_use = \Drafts
  }
  mailbox "Sent Items" {
    special_use = \Sent
  }
  mailbox "Junk Email" {
    auto = subscribe
    special_use = \Junk
  }
  prefix =
}
CONF

sub fake_doveconf {
    my ( $text, $rc ) = @_;
    File::Slurper::Temp::write_text( "$bin/doveconf", "#!/bin/sh\ncat <<'END'\n${text}END\nexit " . ( $rc // 0 ) . "\n" );
    chmod 0755, "$bin/doveconf" or die "chmod $bin/doveconf: $!";
    return;
}
fake_doveconf($doveconf);

sub train {
    my (@args) = @_;
    unlink $log;
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    my @calls = -e $log ? read_lines($log) : ();
    return { rc => $? >> 8, err => $err // q{}, calls => \@calls };
}

# A folder of a maildir, with one message in each of cur and new, as dovecot
# stores it.  INBOX is the maildir itself.
sub folder {
    my ( $maildir, $name ) = @_;
    my $dir = $name eq 'INBOX' ? $maildir : "$maildir/.$name";
    foreach my $sub (qw{cur new tmp}) {
        make_path("$dir/$sub");
    }
    File::Slurper::Temp::write_text( "$dir/cur/1.msg:2,S", "Subject: x\n\nbody\n" );
    File::Slurper::Temp::write_text( "$dir/new/2.msg",     "Subject: x\n\nbody\n" );
    return $dir;
}

# What the calls learned from, as a list of folders with the kind.
sub learned {
    my ( $calls, $kind ) = @_;
    my %seen;
    foreach my $call ( grep { m/--\Q$kind\E[ ]/ } @$calls ) {
        my ($dir) = $call =~ m{--\Q$kind\E[ ](.*)\z} or next;
        $dir =~ s{/(?:cur|new)\z}{};
        $seen{$dir} = 1;
    }
    return [ sort keys %seen ];
}

subtest 'spam is Junk and the folders named, ham is every other folder, and four kinds go to neither' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    my %dir     = map { $_ => folder( $maildir, $_ ) } (
        qw{INBOX INBOX.$suspicious INBOX.$spam Bin Entwuerfe Receipts INBOX.Family},
        'Junk Email', 'Sent Items',
    );
    folder( $maildir, 'Junk' );    # By name only: this dovecot does not give it the special use.

    my $r = train( qw{--spam-folder INBOX.$suspicious --spam-folder INBOX.$spam}, $maildir );
    is( $r->{rc}, 0, 'it succeeds' ) or diag $r->{err};

    is_deeply(
        learned( $r->{calls}, 'spam' ),
        [ sort @dir{ 'Junk Email', qw{INBOX.$suspicious INBOX.$spam} } ],
        'the folder with the Junk special use and each folder that is named are spam'
    ) or diag explain $r->{calls};
    is_deeply(
        learned( $r->{calls}, 'ham' ),
        [ sort( @dir{qw{Receipts INBOX.Family}}, "$maildir/.Junk" ) ],
        'every other folder is ham, including a folder called Junk that has no special use'
    ) or diag explain $r->{calls};

    my @all = ( @{ learned( $r->{calls}, 'spam' ) }, @{ learned( $r->{calls}, 'ham' ) } );
    foreach my $never ( qw{INBOX Bin Entwuerfe}, 'Sent Items' ) {
        is( scalar( grep { $_ eq $dir{$never} } @all ), 0, "$never goes to neither" );
    }
    is( scalar( grep { m{--(?:spam|ham)[ ]\Q$maildir\E/(?:cur|new)\z} } @{ $r->{calls} } ), 0, 'and no call names the INBOX, read or not' ) or diag explain $r->{calls};

    my @spam_calls = grep { index( $_, '--spam' ) >= 0 } @{ $r->{calls} };
    ok( scalar( grep { m{/[.]Junk[ ]Email/new\z} } @spam_calls ),        'spam that nobody opened, which dovecot keeps in new, is learned' ) or diag explain \@spam_calls;
    ok( scalar( grep { m{/[.]Junk[ ]Email/cur\z} } @spam_calls ),        'and so is the spam in cur' );
    ok( !scalar( grep { substr( $_, -4 ) eq '/tmp' } @{ $r->{calls} } ), 'tmp is not learned' );
};

subtest 'a folder that dovecot gives a special use is found by the use, not the name' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    my $junk    = folder( $maildir, 'Junk' );
    my $bin_dir = folder( $maildir, 'Bin' );

    my $r = train($maildir);
    is_deeply( learned( $r->{calls}, 'spam' ), [],      'Junk is not spam by its name' )                     or diag explain $r->{calls};
    is_deeply( learned( $r->{calls}, 'ham' ),  [$junk], 'it is ham with the others, and Bin is left alone' ) or diag explain $r->{calls};
    unlike( join( "\n", @{ $r->{calls} } ), qr{\Q$bin_dir\E}, 'the folder with the Trash special use is not learned' );
};

subtest 'an alias of a folder, which the mailbox_alias plugin makes a link, is not learned again' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    my $target  = folder( $maildir, 'Junk Email' );
    symlink( $target, "$maildir/.Junk" ) or die "symlink: $!";

    my $r = train($maildir);
    is_deeply( learned( $r->{calls}, 'spam' ), [$target], 'the target is spam' )                                      or diag explain $r->{calls};
    is_deeply( learned( $r->{calls}, 'ham' ),  [],        'and the link is not ham, though Junk has no special use' ) or diag explain $r->{calls};
};

subtest 'dovecot that cannot say its special uses stops the training' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    folder( $maildir, 'Bin' );
    fake_doveconf( q{}, 1 );
    my $r = train($maildir);
    fake_doveconf($doveconf);

    isnt( $r->{rc}, 0, 'it fails, because Trash would be learned as ham' );
    is( scalar( grep { m/--spam|--ham/ } @{ $r->{calls} } ), 0,                                                      'and learns nothing' ) or diag explain $r->{calls};
    is( $r->{calls}[-1],                                     'chown -R amavis:amavis /var/lib/amavis/.spamassassin', 'but gives the database back' );
};

subtest 'every learn writes to the database of amavis, which gets it back' => sub {
    my $maildir = tempdir( CLEANUP => 1 ) . '/Maildir';
    folder( $maildir, 'Junk Email' );
    folder( $maildir, 'Receipts' );

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
