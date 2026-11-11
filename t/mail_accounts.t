#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/mail_accounts.t - bin/add_mail_user, bin/reset_mail_password and bin/remove_mail_user, against a scratch configuration and a throwaway secret store

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Slurper();
use File::Slurper::Temp();
use File::Temp();
use IPC::Run3();
use YAML::XS();
use Crypt::KeyDerivation();
use MIME::Base64();

use Provisioner::Cookbook();
use Provisioner::MailAccount();
use Trog::Credentials();
use Trog::Secrets();

my $DOMAIN = 'mail.test.test';
my $CONFIG = $ENV{TROG_PROVISIONER_CONFIG};

require_ok("$FindBin::Bin/../bin/add_mail_user")       or die "could not require add_mail_user: $@";
require_ok("$FindBin::Bin/../bin/reset_mail_password") or die "could not require reset_mail_password: $@";
require_ok("$FindBin::Bin/../bin/remove_mail_user")    or die "could not require remove_mail_user: $@";

# A guest that is this machine, with the files of the guest in a scratch
# directory.  It runs what the library asks it to run, with the sudo taken off,
# so the temporary file and the rename are the real ones.
{

    package FakeGuest;

    use IPC::Run3();

    sub new { my ( $class, %own ) = @_; return bless { log => [], %own }, $class }

    sub run_cmd {
        my ( $self, @argv ) = @_;
        splice( @argv, 0, 2 ) if $argv[0] eq 'sudo';
        push @{ $self->{log} }, join( q{ }, @argv );
        return system(@argv) >> 8;
    }

    sub capture_cmd {
        my ( $self, $cmd ) = @_;
        return "5000\n" if $cmd =~ m/\Aid[ ]-u[ ]dovecot/;
        $cmd =~ s/\Asudo[ ]-n[ ]//;
        push @{ $self->{log} }, $cmd;
        IPC::Run3::run3( $cmd, \undef, \my $out, undef );
        return $out;
    }

    sub write_text {
        my ( $self, $path, $content, %opts ) = @_;
        return 0 if $self->{refuse_writes};
        return 0 if $self->{refuse_matching} && $path =~ $self->{refuse_matching};
        File::Slurper::Temp::write_text( $path, $content );
        return 1;
    }
}

# A doveadm that writes down what it was asked, and says that no mailbox is
# there, so that the create always runs.
my $bin = File::Temp::tempdir( CLEANUP => 1 );
{
    open( my $fh, '>', "$bin/doveadm" ) or die "doveadm: $!";
    print {$fh} qq{#!/bin/sh\necho "\$*" >> "\$DOVEADM_LOG"\ntest "\$1 \$2" = "mailbox status" && exit 1\ntest "\$1" = kick && exit \${KICK_EXIT:-0}\nexit 0\n};
    close($fh) or die "doveadm: $!";
    chmod 0755, "$bin/doveadm";
}

# A postmap that writes down what it was asked, and can be told to fail.
{
    open( my $fh, '>', "$bin/postmap" ) or die "postmap: $!";
    print {$fh} qq{#!/bin/sh\necho "\$*" >> "\$POSTMAP_LOG"\nexit \${POSTMAP_EXIT:-0}\n};
    close($fh) or die "postmap: $!";
    chmod 0755, "$bin/postmap";
}

# The postfix tables of the guest: the lines of two accounts, and the catchall
# line of the build, last.
my %TABLE = (
    sender_login => "# Who can put what in MAIL FROM, for $DOMAIN.\n\nold\@$DOMAIN old\@$DOMAIN\nghost\@$DOMAIN ghost\@$DOMAIN\n",
    virtual_maps => "\nold\@$DOMAIN $DOMAIN/old\nghost\@$DOMAIN $DOMAIN/ghost\n\@$DOMAIN $DOMAIN/catchall\n",

    # The wildcard line at the end is why an account needs a line of its own here.
    virtual_aliases => "\nroot\@$DOMAIN someone\@elsewhere.test\n\nold\@$DOMAIN old\@$DOMAIN\nghost\@$DOMAIN ghost\@$DOMAIN\ncatchall\@$DOMAIN catchall\@$DOMAIN\n\@$DOMAIN catchall\@$DOMAIN\n",
);

# The passwd-file of the guest, the store, and the configuration.
my $OLD_HASH = '{ARGON2ID}$argon2id$v=19$m=65536,t=3,p=1$b2xkc2FsdA$b2xkaGFzaA';
my $PASSWD   = <<"END";
# Mail passwd for $DOMAIN
old\@$DOMAIN:$OLD_HASH:5000:5000:Old:/mail/$DOMAIN/old:/usr/sbin/noshell
ghost\@$DOMAIN:{ARGON2ID}\$argon2id\$v=19\$m=65536,t=3,p=1\$Z2hvc3RzYWx0\$Z2hvc3RoYXNo:5000:5000:Ghost:/mail/$DOMAIN/ghost:/usr/sbin/noshell
catchall\@${DOMAIN}:::::/mail/$DOMAIN/catchall:/usr/sbin/noshell
END

# Other content in the file of the domain, which a tool must not lose.
my $OWN = {
    $DOMAIN => {
        nginx => { sites => ['www'] },
        mail  => { names => { old => { password => "secret:mail/$DOMAIN-old/password", gecos => 'Old', mailboxes => ['INBOX.keep'] } } },
    },
};

# Returns ( $guest, $root, $kdbx, $log ): a fresh world for one subtest.
sub world {
    my %opts = @_;

    my $root = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$root/$DOMAIN" or die "mkdir: $!";
    File::Slurper::Temp::write_text( "$root/$DOMAIN/passwd", $PASSWD );
    chmod 0640, "$root/$DOMAIN/passwd";

    mkdir "$root/postfix"         or die "mkdir: $!";
    mkdir "$root/postfix/$DOMAIN" or die "mkdir: $!";
    foreach my $table ( keys %TABLE ) {
        File::Slurper::Temp::write_text( "$root/postfix/$DOMAIN/$table", $TABLE{$table} );
        chmod 0600, "$root/postfix/$DOMAIN/$table";
    }
    File::Slurper::Temp::write_text( "$root/postmap.log", q{} );

    my $dir = "$CONFIG/recipes.d";
    mkdir $dir unless -d $dir;
    File::Slurper::Temp::write_text( "$CONFIG/recipes.yaml", YAML::XS::Dump( { _base => { _global => {} }, $DOMAIN => { _global => {} } } ) );
    File::Slurper::Temp::write_text( "$dir/$DOMAIN.yaml",    YAML::XS::Dump($OWN) );
    Provisioner::Cookbook->forget();

    my $kdbx = "$CONFIG/secrets.kdbx";
    unlink $kdbx;
    Trog::Secrets->create( $kdbx, 'throwaway', 'secret:seed/entry/password' => 'already here' );
    Trog::Credentials->forget();
    Trog::Credentials->remember( keepass => 'throwaway' );

    my $log = "$root/doveadm.log";
    File::Slurper::Temp::write_text( $log, q{} );
    my $guest = FakeGuest->new(%opts);
    return ( $guest, $root, $kdbx, $log );
}

# Runs a bin with the password on standard input, with the guest and the mail
# root in place.
sub run_tool {
    my ( $tool, $guest, $root, $password, @args ) = @_;

    my $fh = File::Temp->new();
    print {$fh} "$password\n";
    close($fh) or die "close: $!";

    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine( guest_of => sub { return $guest } );

    local $Provisioner::MailAccount::MAIL_ROOT    = $root;
    local $Provisioner::MailAccount::POSTFIX_ROOT = "$root/postfix";
    local $ENV{PATH}                              = "$bin:$ENV{PATH}";
    local $ENV{DOVEADM_LOG}                       = "$root/doveadm.log";
    local $ENV{POSTMAP_LOG}                       = "$root/postmap.log";
    open( local *STDIN, '<', $fh->filename ) or die "stdin: $!";

    my $main = "Provisioner::Bin::${tool}::main";
    no strict 'refs';
    return $main->( '--stdin', @args );
}

sub passwd_of { my ($root) = @_; return File::Slurper::read_text("$root/$DOMAIN/passwd") }
sub table_of { my ( $root, $table ) = @_; return File::Slurper::read_text("$root/postfix/$DOMAIN/$table") }

# The tables that postmap was run on, in order.
sub postmapped {
    my ($root) = @_;
    return map { s{\Ahash:\Q$root\E/postfix/\Q$DOMAIN\E/}{}r } split( m/\n/, File::Slurper::read_text("$root/postmap.log") );
}
sub own_file { return File::Slurper::read_binary("$CONFIG/recipes.d/$DOMAIN.yaml") }

# undef where the store has no such entry, or no such group, which it says by dying.
sub secret_of {
    my ( $kdbx, $ref ) = @_;
    my %got = eval { Trog::Secrets->lookup( $kdbx, 'throwaway', probe => $ref ) };
    return $got{probe};
}

sub temp_files {
    my ($root) = @_;
    return grep { m/\A[.]passwd[.]/ } map { s{.*/}{}r } glob "'$root/$DOMAIN'/.*";
}

# Does the hash of a line make the password, the way dovecot checks it.
sub verifies {
    my ( $hash, $password ) = @_;
    my $part  = qr/([^\$]+)/;
    my $costs = qr/m=(\d+),t=(\d+),p=(\d+)/;
    my ( $memory, $time, $lanes, $salt, $digest ) = $hash =~ m/\A\{ARGON2ID\}\$argon2id\$v=19\$$costs\$$part\$$part\z/ or return 0;
    my $got = Crypt::KeyDerivation::argon2_pbkdf( 'argon2id', $password, MIME::Base64::decode_base64($salt), $time, $memory, $lanes, 32 );
    return $got eq MIME::Base64::decode_base64($digest) ? 1 : 0;
}

subtest 'the line is exactly what the template renders' => sub {
    is(
        Provisioner::MailAccount::passwd_line( domain => $DOMAIN, name => 'someone', gecos => 'Some One', hash => '{ARGON2ID}H', uid => 5000 ),
        "someone\@$DOMAIN:{ARGON2ID}H:5000:5000:Some One:/mail/$DOMAIN/someone:/usr/sbin/noshell",
        'the fields in the order of the passwd-file'
    );
    like( Provisioner::MailAccount::passwd_line( domain => $DOMAIN, name => 'someone', gecos => 'x', hash => 'H' ), qr/:%REPLACEME%:%REPLACEME%:/, 'with the placeholder that the build replaces, where there is no uid' );

    like( exception { Provisioner::MailAccount::passwd_line( domain => $DOMAIN, name => 'some:one', gecos => 'x',    hash => 'H' ) }, qr/not[ ]'some:one'/, 'a colon in the name is refused' );
    like( exception { Provisioner::MailAccount::passwd_line( domain => $DOMAIN, name => 'someone',  gecos => "x:y",  hash => 'H' ) }, qr/colon/,            'and one in the gecos' );
    like( exception { Provisioner::MailAccount::passwd_line( domain => $DOMAIN, name => 'someone',  gecos => "x\ny", hash => 'H' ) }, qr/line[ ]break/,     'and a line break' );
};

subtest 'a line is replaced, added and removed, and nothing else moves' => sub {
    my $hash = '{ARGON2ID}NEW';
    my $text = Provisioner::MailAccount::replace_hash( $PASSWD, "old\@$DOMAIN", $hash );
    ( my $want = $PASSWD ) =~ s/\Q$OLD_HASH\E/$hash/;
    is( $text, $want, 'only the hash of that line changes' );

    like( exception { Provisioner::MailAccount::replace_hash( $PASSWD,          "nobody\@$DOMAIN", $hash ) }, qr/not[ ]in[ ]the[ ]passwd-file/, 'an address that is not there is refused' );
    like( exception { Provisioner::MailAccount::replace_hash( "$PASSWD$PASSWD", "old\@$DOMAIN",    $hash ) }, qr/2[ ]times/,                    'and one that is there twice' );

    my $tail = "xold\@$DOMAIN:{ARGON2ID}TAIL:1:1::/x:/y\n";
    is( Provisioner::MailAccount::replace_hash( $tail . $PASSWD, "old\@$DOMAIN", $hash ), $tail . $want, 'a line that ends like it is not the one that changes' );

    is( Provisioner::MailAccount::remove_line( $PASSWD, "ghost\@$DOMAIN" ), $PASSWD =~ s/^ghost\N*\n//mr, 'a removed line takes only its own line' );
};

subtest 'an account is added to the store, the guest and the configuration' => sub {
    my ( $guest, $root, $kdbx, $log ) = world();
    my $before = own_file();
    my @inode  = ( stat "$root/$DOMAIN/passwd" )[1];

    my @flags = ( '--secrets', $kdbx, '--gecos', 'New One', qw{--mailbox INBOX.a --mailbox INBOX.b} );
    my $rc    = run_tool( 'add_mail_user', $guest, $root, 'new-secret', @flags, $DOMAIN, 'newbie' );
    is( $rc, 0, 'it reports success' );

    my $text  = passwd_of($root);
    my @lines = grep { m/\Anewbie\@/ } split( m/\n/, $text );
    is( scalar @lines, 1, 'the guest has one line for it' );
    my @field = split( m/:/, $lines[0], -1 );
    is_deeply( [ @field[ 0, 2 .. 6 ] ], [ "newbie\@$DOMAIN", 5000, 5000, 'New One', "/mail/$DOMAIN/newbie", '/usr/sbin/noshell' ], 'with the uid of dovecot, and its home' );
    ok( verifies( $field[1], 'new-secret' ), 'and the Argon2id hash of the password' );
    is( $text =~ s/^newbie\N*\n//mr, $PASSWD, 'every other line is as it was' );

    is( ( stat "$root/$DOMAIN/passwd" )[2] & oct 7777, oct 640, 'the file keeps its mode' );
    isnt( ( stat "$root/$DOMAIN/passwd" )[1], $inode[0], 'and it is a new file in place of the old one, which is how a rename leaves it' );
    is_deeply( [ temp_files($root) ], [], 'no temporary file is left' );
    my $dir = quotemeta "$root/$DOMAIN";
    like( join( "\n", @{ $guest->{log} } ), qr{mv[ ]-f[ ]'$dir/[.]passwd[.]\w+'[ ]'$dir/passwd'}, 'it was a rename of a temporary file in the same directory' );

    is( secret_of( $kdbx, "secret:mail/$DOMAIN-newbie/password" ), 'new-secret', 'the store holds the password under the name the recipe settles on' );

    my $own = YAML::XS::Load( own_file() );
    is_deeply(
        $own->{$DOMAIN}{mail}{names}{newbie},
        { password => "secret:mail/$DOMAIN-newbie/password", gecos => 'New One', mailboxes => [ 'INBOX.a', 'INBOX.b' ] },
        'the configuration holds the account, with a reference and not the password'
    );
    is_deeply( $own->{$DOMAIN}{mail}{names}{old}, $OWN->{$DOMAIN}{mail}{names}{old}, 'and the accounts that were there' );
    is_deeply( $own->{$DOMAIN}{nginx},            $OWN->{$DOMAIN}{nginx},            'and the rest of the file, which is not about mail' );
    unlike( own_file(), qr/new-secret/, 'and the password is not in it' );

    my $said = File::Slurper::read_text($log);
    like( $said, qr/^mailbox[ ]create[ ]-u[ ]newbie\@\Q$DOMAIN\E[ ]INBOX[.]a$/m, 'doveadm made the first mailbox' );
    like( $said, qr/^mailbox[ ]create[ ]-u[ ]newbie\@\Q$DOMAIN\E[ ]INBOX[.]b$/m, 'and the second' );
    isnt( own_file(), $before, 'the configuration changed' );
};

subtest 'an account that is already there is refused, and nothing changes' => sub {
    my ( $guest, $root, $kdbx ) = world();
    my $before = own_file();

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'old' ) }, qr/already[ ]in[ ]the[ ]configuration/, 'one in the configuration is refused' );

    # The configuration does not name it, and the passwd-file does.
    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'ghost' ) }, qr/already[ ]in[ ].*passwd[ ]on[ ]the[ ]guest/, 'and one in the passwd-file' );

    is( passwd_of($root),                                         $PASSWD, 'the guest is as it was' );
    is( own_file(),                                               $before, 'and the configuration' );
    is( secret_of( $kdbx, "secret:mail/$DOMAIN-ghost/password" ), undef,   'and nothing was stored' );
};

subtest 'a write that fails leaves the guest, the store and the configuration as they were' => sub {
    my ( $guest, $root, $kdbx ) = world( refuse_writes => 1 );
    my $before = own_file();

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ) }, qr/Could[ ]not[ ]write/, 'it stops, and says so' );
    is( passwd_of($root), $PASSWD, 'the passwd-file is whole' );
    is( own_file(),       $before, 'the configuration does not name an account that the guest lacks' );
    is_deeply( [ temp_files($root) ], [], 'and the temporary file is gone' );
};

subtest 'a reset replaces the hash of one line and the value in the store' => sub {
    my ( $guest, $root, $kdbx, $log ) = world();

    is( run_tool( 'add_mail_user', $guest, $root, 'first-secret', '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'an account with a password' );
    my $with = passwd_of($root);
    my $own  = own_file();

    is( run_tool( 'reset_mail_password', $guest, $root, 'second-secret', '--secrets', $kdbx, '--kick', $DOMAIN, 'newbie' ), 0, 'it resets the password' );

    my $text  = passwd_of($root);
    my ($new) = grep { m/\Anewbie\@/ } split( m/\n/, $text );
    my ($was) = grep { m/\Anewbie\@/ } split( m/\n/, $with );
    my @new   = split( m/:/, $new, -1 );
    my @was   = split( m/:/, $was, -1 );
    ok( verifies( $new[1],  'second-secret' ), 'the new password fits the hash' );
    ok( !verifies( $new[1], 'first-secret' ),  'and the old one does not' );
    is_deeply( [ @new[ 0, 2 .. $#new ] ], [ @was[ 0, 2 .. $#was ] ], 'the rest of that line is as it was' );
    is( $text =~ s/^newbie\N*\n//mr, $with =~ s/^newbie\N*\n//mr, 'and every other line is the same, byte for byte' );
    is_deeply( [ temp_files($root) ], [], 'no temporary file is left' );

    is( secret_of( $kdbx, "secret:mail/$DOMAIN-newbie/password" ), 'second-secret', 'the store holds the new value' );
    is( own_file(),                                                $own,            'and the configuration is the same file, because the reference does not change' );
    like( File::Slurper::read_text($log), qr/^kick[ ]newbie\@\Q$DOMAIN\E$/m, 'doveadm kicked the sessions of the account' );
};

subtest 'a reset of an account that is not in mail.names is refused' => sub {
    my ( $guest, $root, $kdbx ) = world();

    # ghost is in the passwd-file of the guest, so only the configuration refuses.
    like( exception { run_tool( 'reset_mail_password', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'ghost' ) }, qr/not[ ]in[ ]mail[.]names/, 'an account that the configuration lacks' );
    is( passwd_of($root),                                         $PASSWD, 'and the guest is as it was' );
    is( secret_of( $kdbx, "secret:mail/$DOMAIN-ghost/password" ), undef,   'and nothing was stored' );

    # The configuration names it, and the guest does not.
    File::Slurper::Temp::write_text( "$root/$DOMAIN/passwd", $PASSWD =~ s/^old\N*\n//mr );
    like( exception { run_tool( 'reset_mail_password', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'old' ) }, qr/not[ ]in[ ].*passwd[ ]on[ ]the[ ]guest/, 'and one that the guest lacks' );
};

subtest 'a reset of a password written into the configuration is refused' => sub {
    my ( $guest, $root, $kdbx ) = world();
    my $literal = { $DOMAIN => { mail => { names => { plain => { password => 'in the clear', gecos => 'Plain' } } } } };
    File::Slurper::Temp::write_text( "$CONFIG/recipes.d/$DOMAIN.yaml", YAML::XS::Dump($literal) );
    Provisioner::Cookbook->forget();

    like( exception { run_tool( 'reset_mail_password', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'plain' ) }, qr/not[ ]a[ ]secret:[ ]reference/, 'there is no entry in the store to replace' );
};

subtest 'a kick of an account with no session is not a failure' => sub {
    my ( $guest, $root, $kdbx ) = world();
    local $ENV{KICK_EXIT} = 2;

    is( run_tool( 'reset_mail_password', $guest, $root, 'again', '--secrets', $kdbx, '--kick', $DOMAIN, 'old' ), 0, 'the reset still succeeds' );
    ok( verifies( ( split( m/:/, ( grep { m/\Aold\@/ } split( m/\n/, passwd_of($root) ) )[0] ) )[1], 'again' ), 'and the password is the new one' );
};

subtest 'an account is removed from all three, and its mail stays' => sub {
    my ( $guest, $root, $kdbx ) = world();
    mkdir "$root/$DOMAIN/old" or die "mkdir: $!";
    File::Slurper::Temp::write_text( "$root/$DOMAIN/old/message", 'mail' );

    is( run_tool( 'add_mail_user', $guest, $root, 'gone-soon', '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'an account to remove' );
    my $own = YAML::XS::Load( own_file() );
    ok( exists $own->{$DOMAIN}{mail}{names}{newbie}, 'which the configuration holds' );

    {
        my $mock = Test::MockModule->new('Trog::Hypervisors');
        $mock->redefine( guest_of => sub { return $guest } );
        local $Provisioner::MailAccount::MAIL_ROOT    = $root;
        local $Provisioner::MailAccount::POSTFIX_ROOT = "$root/postfix";
        local $ENV{PATH}                              = "$bin:$ENV{PATH}";
        local $ENV{DOVEADM_LOG}                       = "$root/doveadm.log";
        local $ENV{POSTMAP_LOG}                       = "$root/postmap.log";
        is( Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'it reports success' );
        is( Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'old' ),    0, 'and one that was there from the start' );
        like( exception { Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'nobody' ) }, qr/Nothing[ ]was[ ]changed/, 'an account that is nowhere is refused' );
    }

    unlike( passwd_of($root), qr/^(?:newbie|old)\@/m, 'the lines are gone from the guest' );
    like( passwd_of($root), qr/^ghost\@/m, 'and the others stay' );
    my $left = YAML::XS::Load( own_file() );
    is_deeply( $left->{$DOMAIN}{mail}{names}, {},                     'the configuration lists neither' );
    is_deeply( $left->{$DOMAIN}{nginx},       $OWN->{$DOMAIN}{nginx}, 'and keeps the rest of the file' );
    is( secret_of( $kdbx, "secret:mail/$DOMAIN-newbie/password" ), undef,          'the store forgot the secret' );
    is( secret_of( $kdbx, 'secret:seed/entry/password' ),          'already here', 'and kept the others' );
    ok( -f "$root/$DOMAIN/old/message", 'the mail of the account is still on the guest' );    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- the question is whether the file is there
};

subtest 'an account that recipes.yaml holds cannot be changed from recipes.d' => sub {
    my ( $guest, $root, $kdbx ) = world();
    File::Slurper::Temp::write_text( "$CONFIG/recipes.yaml", YAML::XS::Dump( { _base => { _global => {} }, $DOMAIN => { _global => {}, mail => { names => { fixed => { password => 'secret:a/b/password', gecos => 'Fixed' } } } } } ) );
    Provisioner::Cookbook->forget();
    my $before = own_file();

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ) }, qr/does[ ]not[ ]override[ ]it/, 'the add stops, and says where to change it' );
    is( own_file(),                                                $before, 'without a change to recipes.d' );
    is( passwd_of($root),                                          $PASSWD, 'or to the guest, which is the reason to ask first' );
    is( secret_of( $kdbx, "secret:mail/$DOMAIN-newbie/password" ), undef,   'or to the store' );
};

subtest 'the lines of the postfix tables' => sub {
    is( Provisioner::MailAccount::sender_login_line("someone\@$DOMAIN"),                     "someone\@$DOMAIN someone\@$DOMAIN", 'an account owns its own address' );
    is( Provisioner::MailAccount::sender_login_line( "sales\@$DOMAIN", "someone\@$DOMAIN" ), "sales\@$DOMAIN someone\@$DOMAIN",   'and an alias has its owner' );
    is( Provisioner::MailAccount::virtual_maps_line( $DOMAIN, 'someone' ),                   "someone\@$DOMAIN $DOMAIN/someone",  'the mailbox is under the domain' );
    is( Provisioner::MailAccount::virtual_aliases_line( $DOMAIN, 'someone' ),                "someone\@$DOMAIN someone\@$DOMAIN", 'an alias line keeps the address' );

    like( exception { Provisioner::MailAccount::sender_login_line('a b') },                 qr/space/,              'a space in an address is refused' );
    like( exception { Provisioner::MailAccount::sender_login_line( 'a', "b\nc" ) },         qr/line[ ]break/,       'and a line break in an owner' );
    like( exception { Provisioner::MailAccount::virtual_maps_line( $DOMAIN, 'some one' ) }, qr/not[ ]'some[ ]one'/, 'a name that the table cannot hold is refused' );
    like( exception { Provisioner::MailAccount::virtual_maps_line( 'a b', 'someone' ) },    qr/not[ ]'a[ ]b'/,      'and a domain' );
};

subtest 'check_domain judges a domain with Data::Validate::Domain' => sub {
    is( Provisioner::MailAccount::check_domain($DOMAIN),         1, 'a domain under a reserved top-level domain passes' );
    is( Provisioner::MailAccount::check_domain('mail.private1'), 1, 'and one under a private top-level domain' );
    is( Provisioner::MailAccount::check_domain('a-b.test'),      1, 'and a hyphen inside a label' );

    my %bad = (
        'a:b.test'   => 'a colon',
        'a b.test'   => 'a space',
        'a/b.test'   => 'a slash',
        "a.test\n"   => 'a line break',
        q{}          => 'an empty string',
        'a_b.test'   => 'an underscore, which the old rule let through',
        'Mail.Test'  => 'upper case, because the recipe and the paths are in lower case',
        'a.test.'    => 'a dot at the end',
        'localhost1' => 'a name of one label',
    );
    foreach my $domain ( sort keys %bad ) {
        like( exception { Provisioner::MailAccount::check_domain($domain) }, qr/domain[ ]name[ ]in[ ]lower[ ]case/, "$bad{$domain} is refused" );
    }
    like( exception { Provisioner::MailAccount::check_domain(undef) }, qr/domain[ ]name[ ]in[ ]lower[ ]case/, 'and so is no domain' );
};

subtest 'a table line is added above the catchall, and removed alone' => sub {
    my $line = Provisioner::MailAccount::virtual_maps_line( $DOMAIN, 'newbie' );

    my $added = Provisioner::MailAccount::add_table_line( $TABLE{virtual_maps}, $line, $DOMAIN );
    is( $added,                                                             "\nold\@$DOMAIN $DOMAIN/old\nghost\@$DOMAIN $DOMAIN/ghost\n$line\n\@$DOMAIN $DOMAIN/catchall\n", 'it is above the catchall line, and every other line is as it was' );
    is( Provisioner::MailAccount::add_table_line( $added, $line, $DOMAIN ), $added,                                                                                          'a line that is there changes nothing' );
    like( exception { Provisioner::MailAccount::add_table_line( $added, "newbie\@$DOMAIN elsewhere", $DOMAIN ) }, qr/another[ ]value/, 'but the same address with another value is refused' );

    is( Provisioner::MailAccount::add_table_line( $TABLE{sender_login}, "newbie\@$DOMAIN newbie\@$DOMAIN", $DOMAIN ), "$TABLE{sender_login}newbie\@$DOMAIN newbie\@$DOMAIN\n", 'a table with no catchall line gets it at the end' );
    is( Provisioner::MailAccount::add_table_line( 'x@y y/x',            "n\@y y/n",                        'y' ),     "x\@y y/x\nn\@y y/n\n",                                  'also where the last line has no line break' );

    is( Provisioner::MailAccount::remove_table_line( $added,                              "newbie\@$DOMAIN" ), $TABLE{virtual_maps}, 'a removed line takes only its own' );
    is( Provisioner::MailAccount::remove_table_line( $TABLE{virtual_maps},                "nobody\@$DOMAIN" ), $TABLE{virtual_maps}, 'and an address that is not there changes nothing' );
    is( Provisioner::MailAccount::remove_table_line( "xold\@$DOMAIN a\nold\@$DOMAIN b\n", "old\@$DOMAIN" ),    "xold\@$DOMAIN a\n",  'a line that ends like it is kept' );
};

subtest 'an added account is in both tables, above the catchall, and postmap ran on each' => sub {
    my ( $guest, $root, $kdbx ) = world();
    my @inode = map { ( stat "$root/postfix/$DOMAIN/$_" )[1] } qw{sender_login virtual_aliases virtual_maps};

    is( run_tool( 'add_mail_user', $guest, $root, 'new-secret', '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'it reports success' );

    is( table_of( $root, 'sender_login' ), "$TABLE{sender_login}newbie\@$DOMAIN newbie\@$DOMAIN\n", 'the sender may use its own address' );
    is(
        table_of( $root, 'virtual_maps' ),
        "\nold\@$DOMAIN $DOMAIN/old\nghost\@$DOMAIN $DOMAIN/ghost\nnewbie\@$DOMAIN $DOMAIN/newbie\n\@$DOMAIN $DOMAIN/catchall\n",
        'its mail goes to its own mailbox, and the catchall is still last'
    );
    is( table_of( $root, 'virtual_aliases' ), $TABLE{virtual_aliases} =~ s/^(?=\@)/newbie\@$DOMAIN newbie\@$DOMAIN\n/mr, 'and it keeps its own mail out of the wildcard line, which is still last' );
    is_deeply( [ postmapped($root) ], [qw{sender_login virtual_aliases virtual_maps}], 'postmap ran on each table, once' );

    foreach my $table (qw{sender_login virtual_aliases virtual_maps}) {
        is( ( stat "$root/postfix/$DOMAIN/$table" )[2] & oct 7777, oct 600, "$table keeps its mode" );
    }
    my @now = map { ( stat "$root/postfix/$DOMAIN/$_" )[1] } qw{sender_login virtual_aliases virtual_maps};
    isnt( $now[0], $inode[0], 'and each is a new file in place of the old one, which is how a rename leaves it' );
    isnt( $now[1], $inode[1], 'both of them' );
    is_deeply( [ grep { m/\A[.](?:sender_login|virtual_aliases|virtual_maps)[.]/ } map { s{.*/}{}r } glob "'$root/postfix/$DOMAIN'/.*" ], [], 'no temporary file is left' );
    my $dir = quotemeta "$root/postfix/$DOMAIN";
    like( join( "\n", @{ $guest->{log} } ), qr{mv[ ]-f[ ]'$dir/[.]sender_login[.]\w+'[ ]'$dir/sender_login'}, 'it was a rename of a temporary file in the same directory' );
    unlike( join( "\n", @{ $guest->{log} } ), qr/postfix[ ]reload|systemctl/, 'and postfix did not reload' );
};

subtest 'a removed account is in neither table, and postmap ran' => sub {
    my ( $guest, $root, $kdbx ) = world();

    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine( guest_of => sub { return $guest } );
    {
        local $Provisioner::MailAccount::MAIL_ROOT    = $root;
        local $Provisioner::MailAccount::POSTFIX_ROOT = "$root/postfix";
        local $ENV{PATH}                              = "$bin:$ENV{PATH}";
        local $ENV{DOVEADM_LOG}                       = "$root/doveadm.log";
        local $ENV{POSTMAP_LOG}                       = "$root/postmap.log";
        is( Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'old' ), 0, 'it reports success' );
    }

    is( table_of( $root, 'sender_login' ),    $TABLE{sender_login}    =~ s/^old\N*\n//mr, 'the sender table lost its line' );
    is( table_of( $root, 'virtual_maps' ),    $TABLE{virtual_maps}    =~ s/^old\N*\n//mr, 'and so did the mailbox table, which keeps the others and the catchall' );
    is( table_of( $root, 'virtual_aliases' ), $TABLE{virtual_aliases} =~ s/^old\N*\n//mr, 'and the alias table, which keeps the wildcard line' );
    unlike( table_of( $root, $_ ), qr/^old\@/m, "no line for it in $_" ) for qw{sender_login virtual_aliases virtual_maps};
    is_deeply( [ postmapped($root) ], [qw{sender_login virtual_aliases virtual_maps}], 'postmap ran on each table' );
};

subtest 'an added account can be removed, and the tables are as they were' => sub {
    my ( $guest, $root, $kdbx ) = world();
    is( run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'an account to remove' );

    {
        my $mock = Test::MockModule->new('Trog::Hypervisors');
        $mock->redefine( guest_of => sub { return $guest } );
        local $Provisioner::MailAccount::MAIL_ROOT    = $root;
        local $Provisioner::MailAccount::POSTFIX_ROOT = "$root/postfix";
        local $ENV{PATH}                              = "$bin:$ENV{PATH}";
        local $ENV{DOVEADM_LOG}                       = "$root/doveadm.log";
        local $ENV{POSTMAP_LOG}                       = "$root/postmap.log";
        is( Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'it reports success' );
    }
    is( table_of( $root, $_ ), $TABLE{$_}, "$_ is byte for byte as it was" ) for qw{sender_login virtual_aliases virtual_maps};
    is_deeply( [ postmapped($root) ], [qw{sender_login virtual_aliases virtual_maps sender_login virtual_aliases virtual_maps}], 'and postmap ran after each change' );
};

subtest 'an account with no lines in the tables is removed, and the tables stay' => sub {
    my ( $guest, $root, $kdbx ) = world();

    # An account that a tool without the tables made: it has a passwd line only.
    File::Slurper::Temp::write_text( "$root/postfix/$DOMAIN/$_", $TABLE{$_} =~ s/^(?:old|ghost)\N*\n//mgr ) for qw{sender_login virtual_aliases virtual_maps};
    my %before = map { $_ => table_of( $root, $_ ) } qw{sender_login virtual_aliases virtual_maps};

    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine( guest_of => sub { return $guest } );
    {
        local $Provisioner::MailAccount::MAIL_ROOT    = $root;
        local $Provisioner::MailAccount::POSTFIX_ROOT = "$root/postfix";
        local $ENV{PATH}                              = "$bin:$ENV{PATH}";
        local $ENV{DOVEADM_LOG}                       = "$root/doveadm.log";
        local $ENV{POSTMAP_LOG}                       = "$root/postmap.log";
        is( Provisioner::Bin::remove_mail_user::main( '--secrets', $kdbx, $DOMAIN, 'old' ), 0, 'it reports success' );
    }
    unlike( passwd_of($root), qr/^old\@/m, 'the passwd line is gone' );
    is( table_of( $root, $_ ), $before{$_}, "$_ is as it was" ) for qw{sender_login virtual_aliases virtual_maps};
    is_deeply( [ postmapped($root) ], [], 'and postmap did not run' );
};

subtest 'a reset does not touch the tables' => sub {
    my ( $guest, $root, $kdbx ) = world();

    is( run_tool( 'reset_mail_password', $guest, $root, 'again', '--secrets', $kdbx, $DOMAIN, 'old' ), 0,          'the reset succeeds' );
    is( table_of( $root, $_ ),                                                                         $TABLE{$_}, "$_ is as it was" ) for qw{sender_login virtual_aliases virtual_maps};
    is_deeply( [ postmapped($root) ], [], 'and postmap did not run' );
    unlike( join( "\n", @{ $guest->{log} } ), qr{postfix}, 'the guest was not asked about postfix at all' );
};

subtest 'a passwd-file that cannot be written puts both tables back' => sub {
    my ( $guest, $root, $kdbx ) = world( refuse_matching => qr{/[.]passwd[.]} );
    my $before = own_file();

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ) }, qr/Could[ ]not[ ]write/, 'it stops, and says so' );
    is( table_of( $root, $_ ), $TABLE{$_}, "$_ is as it was" ) for qw{sender_login virtual_aliases virtual_maps};
    is_deeply( [ postmapped($root) ], [qw{sender_login virtual_aliases virtual_maps virtual_maps virtual_aliases sender_login}], 'postmap ran after the write and again after the restore, in the opposite order' );
    is( passwd_of($root), $PASSWD, 'the passwd-file is whole' );
    is( own_file(),       $before, 'and the configuration does not name the account' );
    is_deeply( [ grep { m/\A[.]/ && !m/\A[.]{1,2}\z/ } map { s{.*/}{}r } glob("'$root/postfix/$DOMAIN'/.*"), glob("'$root/$DOMAIN'/.*") ], [], 'no temporary file is left in either directory' );

    # Nothing is left that a second run refuses.
    $guest->{refuse_matching} = undef;
    is( run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ), 0, 'a second run succeeds' );
    like( table_of( $root, 'sender_login' ), qr/^newbie\@\Q$DOMAIN\E[ ]newbie\@\Q$DOMAIN\E$/m, 'and the tables hold the account' );
};

subtest 'a postmap that fails puts the tables back too' => sub {
    my ( $guest, $root, $kdbx ) = world();
    local $ENV{POSTMAP_EXIT} = 1;

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ) }, qr/postmap[ ]failed/, 'it stops, and says so' );
    is( table_of( $root, $_ ), $TABLE{$_}, "$_ is as it was" ) for qw{sender_login virtual_aliases virtual_maps};
    is( passwd_of($root),      $PASSWD,    'and the passwd-file was never written' );
};

subtest 'a guest with no tables is refused before anything changes' => sub {
    my ( $guest, $root, $kdbx ) = world();
    unlink "$root/postfix/$DOMAIN/virtual_maps";
    my $before = own_file();

    like( exception { run_tool( 'add_mail_user', $guest, $root, 'x', '--secrets', $kdbx, $DOMAIN, 'newbie' ) }, qr/virtual_maps[ ]does[ ]not[ ]exist/, 'it says which table is missing' );
    is( passwd_of($root),                                          $PASSWD, 'the guest is as it was' );
    is( own_file(),                                                $before, 'and the configuration' );
    is( secret_of( $kdbx, "secret:mail/$DOMAIN-newbie/password" ), undef,   'and nothing was stored' );
};

subtest 'the usage errors' => sub {
    foreach my $tool (qw{add_mail_user reset_mail_password remove_mail_user}) {
        my $out = q{};
        IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/$tool", $DOMAIN ], \undef, \$out, \$out );
        isnt( $?, 0, "$tool with no name exits non-zero" );
        like( $out, qr/Need[ ]a[ ]domain[ ]and[ ]a[ ]name/, 'and says what it needs' );
    }
};

done_testing();
