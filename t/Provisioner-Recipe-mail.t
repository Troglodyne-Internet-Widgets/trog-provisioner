#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
no autovivification;

=head1 NAME

t/Provisioner-Recipe-mail.t - what the mail recipe accepts for its relay, and the accounts it writes

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

use File::Slurper();
use File::Slurper::Temp();
use File::Temp();
use IPC::Run3();

use Provisioner::Cookbook();
use Provisioner::MailAccount();
use Trog::Secrets();

use Crypt::PK::RSA();
use MIME::Base64();

my $recipe = Provisioner::Cookbook->load( 'mail', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
);

my %BASE = (
    domain      => 'mail.test.test',
    install_dir => '/nonexistent',
    admin_user  => 'someadmin',
);

# transport_maps reads relay.to as a list of destinations.
subtest 'relay.to is a list of destinations' => sub {
    my %none = $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25 } );
    is_deeply( $none{relay}{to}, [], 'no destinations by default' );

    my %some = $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25, to => ['other.test.test'] } );
    is_deeply( $some{relay}{to}, ['other.test.test'], 'the destinations given are kept' );

    like(
        exception { $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25, to => 'other.test.test' } ) },
        qr{/relay/to},
        'one destination not in a list is refused'
    );
};

# virtual_maps sends everything unmatched under the domain to its catchall, so
# the account that owns that mailbox has to be under the domain as well.
subtest 'the catchall is an account of the domain it catches for' => sub {
    my $passwd = $recipe->render_file( 'files/mail.passwd.tt', %BASE, names => { someuser => { password => 'x', gecos => 'Some User' } } );

    my @catchall = grep { /^catchall\@/ } split /\n/, $passwd;
    is( scalar @catchall, 1, 'there is one catchall account' ) or diag $passwd;
    my @field = split /:/, $catchall[0] // q{};
    is( $field[0], 'catchall@mail.test.test',       'under the domain' );
    is( $field[5], '/mail/mail.test.test/catchall', 'with its mailbox there too' );

    my ($someuser) = grep { /^someuser\@/ } split /\n/, $passwd;
    like( ( split /:/, $someuser // q{} )[1], qr/\A\{ARGON2ID\}\$argon2id\$/, 'an account with a password gets the Argon2id hash of it, which dovecot reads' );
};

# bin/add_mail_user writes a line to a running guest, and a build writes the same
# account from the template.  Both must make the same line, or a rebuild would
# change an account that a tool made.
subtest 'the template renders the line that the tools write' => sub {

    # A recipe remembers the options it validated, so each render needs its own.
    my $fresh = sub {
        return Provisioner::Cookbook->load( 'mail', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => '/nonexistent', distro => 'ubuntu' );
    };

    my $gecos  = 'Some & User';
    my $passwd = $fresh->()->render_file( 'files/mail.passwd.tt', %BASE, names => { someuser => { password => 'x', gecos => $gecos } } );
    my ($line) = grep { /^someuser\@/ } split /\n/, $passwd;

    my $hash = ( split /:/, $line // q{} )[1];
    is(
        $line,
        Provisioner::MailAccount::passwd_line( domain => $BASE{domain}, name => 'someuser', gecos => $gecos, hash => $hash ),
        'the same bytes, with an ampersand in the gecos that the template does not escape'
    );
    my $names = sub { my %names = @_; return $fresh->()->enrich( $fresh->()->validate( %BASE, names => \%names ) ) };
    like( exception { $names->( 'some:one' => { password => 'x', gecos => 'x' } ) },    qr/not[ ]'some:one'/,     'a name that the file cannot hold stops the build, since the template would only warn' );
    like( exception { $names->( someone    => { password => 'x', gecos => 'x:y' } ) },  qr{/names/someone/gecos}, 'and so does a gecos with a colon' );
    like( exception { $names->( someone    => { password => 'x', gecos => "x\ny" } ) }, qr{/names/someone/gecos}, 'or a line break' );
};

# bin/add_mail_user and bin/remove_mail_user write a line to each postfix table
# of a running guest.  A build renders the same tables, so both must make the
# same lines, or the tools would leave a table that a rebuild changes.
subtest 'the templates render the postfix lines that the tools write' => sub {
    my $fresh = sub {
        return Provisioner::Cookbook->load( 'mail', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => '/nonexistent', distro => 'ubuntu' );
    };
    my %names = ( someuser => { password => 'x', gecos => 'Some User' }, other => { password => 'x', gecos => 'Other' } );

    my $maps = $fresh->()->render_file( 'files/mail.virtual_maps.tt', %BASE, names => {%names} );
    foreach my $name ( sort keys %names ) {
        my $line = Provisioner::MailAccount::virtual_maps_line( $BASE{domain}, $name );
        is( scalar( () = $maps =~ m/^\Q$line\E$/mg ), 1, "virtual_maps has the line of $name once, byte for byte" );
    }
    like( $maps, qr/\n\@\Q$BASE{domain}\E[ ]\Q$BASE{domain}\E\/catchall\n\z/, 'and the catchall line last, which is where the tools add above' );

    my $aliases = $fresh->()->render_file( 'files/mail.virtual_aliases.tt', %BASE, names => {%names} );
    foreach my $name ( sort keys %names ) {
        my $line = Provisioner::MailAccount::virtual_aliases_line( $BASE{domain}, $name );
        is( scalar( () = $aliases =~ m/^\Q$line\E$/mg ), 1, "virtual_aliases has the line of $name once, byte for byte" );
    }
    like( $aliases, qr/\n\@\Q$BASE{domain}\E[ ]catchall\@\Q$BASE{domain}\E\n\z/, 'and the wildcard line last, which is where the tools add above' );

    my $logins = $fresh->()->render_file( 'files/mail.sender_login.tt', %BASE, names => {%names}, mail_aliases => [ { from => 'sales', to => 'someuser' } ] );
    foreach my $name ( sort keys %names ) {
        my $address = Provisioner::MailAccount::address( $BASE{domain}, $name );
        my $line    = Provisioner::MailAccount::sender_login_line($address);
        is( scalar( () = $logins =~ m/^\Q$line\E$/mg ), 1, "sender_login has the line of $name once, byte for byte" );
    }
    my $alias = Provisioner::MailAccount::sender_login_line( "sales\@$BASE{domain}", "someuser\@$BASE{domain}" );
    like( $logins, qr/^\Q$alias\E$/m, 'and the line of an alias, with its owner' );
};

subtest 'an account that only the salvaged passwd-file holds is refused, or kept, and named' => sub {
    my %names = ( names => { someuser => { password => 'x', gecos => 'Some User' } }, script_dir => '/nonexistent', install_dir => '/nonexistent' );

    my %default = $recipe->enrich( $recipe->validate( %BASE, %names ) );
    is( $default{unlisted_accounts}, 'refuse', 'a build refuses by default' );
    like( exception { $recipe->validate( %BASE, %names, unlisted_accounts => 'ignore' ) }, qr{/unlisted_accounts}, 'and nothing else is a choice' );

    # Run what make would hand the shell, in a scratch directory: a new passwd
    # file in the working directory, and a salvaged one with a stray account.
    my $build = sub {
        my (%opts) = @_;

        my $dir = File::Temp::tempdir( CLEANUP => 1 );
        mkdir "$dir/mail" or die "mkdir: $!";
        File::Slurper::Temp::write_text( "$dir/mailpasswd",  "# new\nsomeuser\@mail.test.test:H:1:1:Some:/h:/s\ncatchall\@mail.test.test:::::/h:/s\n" );
        File::Slurper::Temp::write_text( "$dir/mail/passwd", "# old\nsomeuser\@mail.test.test:OLD:1:1:Some:/h:/s\nstray\@mail.test.test:S:1:1:Stray:/h:/s\n" );

        my $fragment = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich( $recipe->validate( %BASE, %names, %opts ) ) );
        my $salvaged = qr{\bmv\b[ ]/mail/mail[.]test[.]test/passwd};
        my @lines    = grep { m/unlisted_accounts|$salvaged/ && !m/\A\#/ } split m/\n/, $fragment;
        s/\$\$/\$/g                             for @lines;
        s{/mail/mail[.]test[.]test}{$dir/mail}g for @lines;

        my ( $out, $status ) = ( q{}, 0 );
        foreach my $line (@lines) {
            my $got;
            IPC::Run3::run3( [ 'bash', '-c', "cd '$dir' && ( $line )" ], \undef, \$got, \$got );
            $out .= $got;
            $status = $? >> 8;
            last if $status;
        }
        return ( $out, $status, File::Slurper::read_text("$dir/mailpasswd"), -e "$dir/mail/passwd" ? 1 : 0 );
    };

    my ( $said, $status, $new, $still_there ) = $build->();
    isnt( $status, 0, 'under refuse, the build stops' );
    like( $said, qr/stray\@mail[.]test[.]test/, 'and the log names the address that only the salvaged file holds' );
    unlike( $said, qr/someuser\@/, 'and not the one that mail.names lists' );
    unlike( $new,  qr/stray/,      'the new file did not take it' );
    is( $still_there, 1, 'and the salvaged file is where it was, so the next run finds the same account' );

    ( $said, $status, $new, $still_there ) = $build->( unlisted_accounts => 'keep' );
    is( $status, 0, 'under keep, the build goes on' );
    like( $said, qr/stray\@mail[.]test[.]test/,                'and the log names the address' );
    like( $new,  qr/^stray\@mail[.]test[.]test:S:1:1:Stray:/m, 'and the new file holds its line, hash and all' );
    is( $still_there, 0, 'and the salvaged file moved aside' );
};

subtest 'a bare name logs in to the domain of the machine, and to no domain built onto it' => sub {
    my $cookbook = Test::MockModule->new( 'Provisioner::Cookbook', no_auto => 1 );
    $cookbook->redefine(
        configuration => sub {
            return { _shared => { 'mail.test.test' => ['hosted.test.test'] }, map { $_ => { mail => {} } } qw{mail.test.test hosted.test.test} };
        }
    );
    my $realm_of = sub {
        my ($domain) = @_;
        my $conf = $recipe->render_raw( 'files/mail.dovecot.domain.tt', $recipe->enrich( $recipe->validate( %BASE, domain => $domain, script_dir => '/nonexistent' ) ) );
        return $conf =~ m/^auth_default_realm[ ]=[ ](\S+)$/m ? $1 : 'none';
    };

    is( $realm_of->('mail.test.test'),   'mail.test.test', 'the machine makes its own domain the default realm' );
    is( $realm_of->('hosted.test.test'), 'none',           'a domain built onto it sets none, so dovecot keeps the realm of the machine' );
};

subtest 'the build makes dovecot read each restored maildir again' => sub {
    my %names    = ( names => { someuser => { password => 'x', gecos => 'Some User' }, other => { password => 'y', gecos => 'Other' } }, script_dir => '/nonexistent' );
    my $fragment = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich( $recipe->validate( %BASE, %names ) ) );
    my @lines    = grep { !m/\A\#/ } split m/\n/, $fragment;

    my @resync = grep { m/doveadm[ ]force-resync/ } @lines;
    is( scalar @resync, 3, 'once for each account, and once for the catchall' ) or diag $fragment;

    # Run as make would hand them to the shell, with a doveadm that writes down
    # what it was asked, and a store where only someuser has a maildir.
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$dir/$_" or die "mkdir: $!" for qw{bin store store/someuser store/someuser/Maildir};
    File::Slurper::Temp::write_text( "$dir/bin/doveadm", qq{#!/bin/sh\necho "\$*" >> "$dir/asked"\n} );
    chmod 0755, "$dir/bin/doveadm" or die "chmod: $!";
    foreach my $line (@resync) {
        my $command = $line =~ s/\$\$/\$/gr =~ s{/mail/mail[.]test[.]test}{$dir/store}gr;
        my $out;
        IPC::Run3::run3( [ 'bash', '-c', "PATH='$dir/bin':\$PATH; $command" ], \undef, \$out, \$out );
        is( $? >> 8, 0, 'the line succeeds' ) or diag $out;
    }
    my $asked = -e "$dir/asked" ? File::Slurper::read_text("$dir/asked") : q{};
    is( $asked, "force-resync -u someuser\@mail.test.test *\n", 'dovecot reads every mailbox of the account that has a maildir, and an account without one is left to the first delivery' );

    # dovecot answers doveadm only once the restart above has run, and the
    # sweep of the modes after it gives the files that doveadm writes to dovecot.
    my ($restart) = grep { $lines[$_] eq 'systemctl restart dovecot' } 0 .. $#lines;
    my ($resync)  = grep { index( $lines[$_], q{force-resync} ) >= 0 } 0 .. $#lines;
    my ($sweep)   = grep { $lines[$_] =~ m{\Achown[ ]-R[ ]dovecot:dovecot[ ]/mail/} } 0 .. $#lines;
    ok( defined $restart && defined $sweep && $restart < $resync && $resync < $sweep, 'after dovecot restarts, and before the store is given to dovecot' ) or diag $fragment;
};

subtest 'a relay that is a mail relay of this installation takes every sender, with a login' => sub {
    my %config   = ( 'relay.test.test' => { mailrelay => {} }, 'web.test.test' => { nginx => {} } );
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( configuration => sub { return {%config} } );
    $cookbook->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $config{$domain} // {} } );
    $cookbook->redefine( host_of       => sub { return } );
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( main_addresses => sub { return { guests => '192.0.2.5' } } );

    my %ours = ( relay => { host => 'relay.test.test' } );
    is_deeply(
        [ $recipe->grants( 'mail.test.test', %ours ) ],
        [ { recipe => 'mailrelay', guest => 'relay.test.test', client => 'mail.test.test' } ],
        'the relay issues it a login'
    );
    is_deeply( [ $recipe->grants( 'mail.test.test', relay => { host => 'smtp.outside.test', port => 25 } ) ], [], 'and a host outside issues none' );
    is_deeply( [ $recipe->grants('mail.test.test') ],                                                         [], 'and nor does no relay' );

    my %opts = $recipe->enrich( $recipe->validate( %BASE, %ours ) );
    is_deeply( $opts{mailrelay_login}, { address => '192.0.2.5', port => 2587, password => '/etc/postfix/mailrelay/mail.test.test.password' }, 'at the address where the guests reach the relay, on its relay port, with the password that it issued' );
    is( $opts{mailrelay}, 'relay.test.test', 'which the templates read as the mail relay, and not as a host outside' );
    is_deeply( $opts{relay_jails}, [qw{dovecot postfix}], 'and every jail of mail is told to leave the relay alone' );
    is( $opts{ban_relay}{action},  'mailrelay-mail.test.test',                       'and to ban through it, with an action of its own' );
    is( $opts{ban_relay}{address}, '192.0.2.5',                                      'at the address where the guests reach it' );
    is( $opts{ban_relay}{key_b64}, '/etc/fail2ban/mailrelay/mail.test.test.key.b64', 'with the key that it issued' );

    %opts = $recipe->enrich( $recipe->validate( %BASE, relay => { host => 'smtp.outside.test', port => 25 } ) );
    is( $opts{mailrelay}, undef, 'a host outside is no mail relay' );
    ok( !exists $opts{mailrelay_login}, 'and gets no login' );

    my $no_relay = qr/web[.]test[.]test,[ ]which[ ]is[ ]a[ ]guest/;
    like( exception { $recipe->grants( 'mail.test.test', relay => { host => 'web.test.test' } ) }, qr/$no_relay.*[ ]runs[ ]no[ ]mailrelay/, 'a guest of ours that runs no mailrelay is refused' );
    like( exception { $recipe->grants( 'mail.test.test', relay => { host => 'relay.test.test', port => 25 } ) },                  qr/relay[.]port[ ]and[ ]relay[.]to/, 'and so is a port for a mail relay, which sets its own' );
    like( exception { $recipe->grants( 'mail.test.test', relay => { host => 'relay.test.test', to   => ['other.test.test'] } ) }, qr/relay[.]port[ ]and[ ]relay[.]to/, 'and destinations, because it takes every sender' );

    # Each sender goes to one place: every sender of the domain to the mail
    # relay, or the listed ones to the host outside.
    my $maps = $recipe->render_raw( 'files/mail.sdd_relay_maps.tt', $recipe->enrich( $recipe->validate( %BASE, %ours ) ) );
    like( $maps, qr/^\@mail[.]test[.]test[ ]\[192[.]0[.]2[.]5\]:2587$/m, 'postfix sends every sender of the domain to the mail relay' );
    unlike( $maps, qr/^root\@/m, 'and to no host outside' );
    $maps = $recipe->render_raw( 'files/mail.sdd_relay_maps.tt', $recipe->enrich( $recipe->validate( %BASE, relay => { host => 'smtp.outside.test', port => 25 } ) ) );
    like( $maps, qr/^root\@mail[.]test[.]test[ ]\[smtp[.]outside[.]test\]:25$/m, 'and a host outside gets the senders that it always got' );
    unlike( $maps, qr/^\@mail[.]test[.]test[ ]/m, 'and not the whole domain' );

    my $guests = Test::MockModule->new('Provisioner::IPPool');
    $guests->redefine( guest_address => sub { my ($domain) = @_; return ( $domain, $domain eq 'mail.test.test' ? '192.0.2.10' : undef ) } );
    is_deeply(
        { $recipe->grant_terms( { recipe => 'mailrelay', guest => 'relay.test.test', client => 'mail.test.test' } ) },
        {
            address   => '192.0.2.10',
            upstreams => { imaps => '192.0.2.10:10993', submissions => '192.0.2.10:10465', pop3s => '192.0.2.10:10995' },
            names     => [qw{mail.test.test mail.mail.test.test}],
        },
        'the relay sends the mail that comes in to the address of the guest, and the mail clients of the domain and of its mail name to the proxy ports there'
    );
    like(
        exception { $recipe->grant_terms( { recipe => 'mailrelay', guest => 'relay.test.test', client => 'none.test.test' } ) },
        qr/none[.]test[.]test[ ]has[ ]no[ ]address/,
        'and a guest that the relay cannot reach stops the build'
    );
};

subtest 'behind a relay of nginx, the settings of mail clients are public names' => sub {
    my $asked = sub {
        my (%config) = @_;
        my $cookbook = Test::MockModule->new( 'Provisioner::Cookbook', no_auto => 1 );
        $cookbook->redefine( configuration => sub { return { 'mail.test.test' => {%config} } } );
        my %required = Provisioner::Cookbook->load('mail')->required_recipes( domain => 'mail.test.test' );
        return { $required{nginx}->() };
    };
    my @sites = qw{autodiscover.mail.test.test autoconfig.mail.test.test};

    my $relayed = $asked->( nginx => { relay => 'relay.test.test' } );
    is_deeply( $relayed->{sites},                          \@sites,                                  'the vhost answers for both names' );
    is_deeply( $relayed->{public_names},                   { map { $_ => { vhost => $_ } } @sites }, 'and the relay sends both to it' );
    is_deeply( [ sort keys %{ $asked->( nginx => {} ) } ], ['sites'],                                'without a relay, mail asks nginx for the vhost alone' );
};

subtest 'ManageSieve claims 4190 on loopback, and on no other address' => sub {
    my %claims = $recipe->claims(%BASE);
    is_deeply( [ sort keys %{ $claims{4190} // {} } ], [qw{127.0.0.1 ::1}], 'on both loopback addresses' );
    %claims = $recipe->claims( %BASE, ipv6 => 0 );
    is_deeply( [ sort keys %{ $claims{4190} // {} } ], ['127.0.0.1'], 'and on 127.0.0.1 alone when ipv6 is off, as dovecot binds it' );
};

subtest 'the DKIM key comes from the store, and its public half is a record' => sub {
    my $mail = Provisioner::Cookbook->load('mail');
    my ($file) = values %{ { $mail->guest_secrets( '/nonexistent', 'mail.test.test' ) } };
    is( $file->{ref}, 'secret:mail/mail.test.test-dkim-key/password', 'the store keeps it for the domain' );

    my $made = $file->{generate}->();
    my $key  = Crypt::PK::RSA->new( \$made );
    ok( $key->is_private, 'the generator makes a private key' );
    is( $key->size * 8, 2048, 'of 2048 bits' );

    local %Trog::Secrets::HELD;
    is_deeply( [ $mail->dkim_records('mail.test.test') ], [], 'without the key, as in a run that opened no store, there is no record' );

    $Trog::Secrets::HELD{ $file->{ref} } = $made;
    my @records = $mail->dkim_records('mail.test.test');
    is_deeply( [ map { $_->{name} } @records ], [qw{default._domainkey.mail.test.test mail._domainkey.mail.test.test}], 'with it, a record for each selector of the key table' );
    my $public = MIME::Base64::encode_base64( $key->export_key_der('public'), q{} );
    is( $records[0]{content}, "v=DKIM1; h=sha256; k=rsa; t=y; p=$public", 'holding the public half of that key' );
    is( $records[0]{match},   'v=DKIM1',                                  'matched by its start, so that a new key replaces it' );
    ok( ( grep { $_->{name} eq 'default._domainkey.mail.test.test' } $mail->dns_records( domain => 'mail.test.test' ) ), 'and among the records of mail' );
};

subtest 'spam_folders is a list that defaults to none, and takes no quote or percent sign' => sub {
    my %account = ( password => 'x', gecos => 'Me' );
    my %none    = $recipe->validate( %BASE, names => { me => {%account} } );
    is_deeply( $none{names}{me}{spam_folders}, [], 'no folders by default' );

    my %some = $recipe->validate( %BASE, names => { me => { %account, spam_folders => [ 'INBOX.$spam', 'INBOX.$suspicious' ] } } );
    is_deeply( $some{names}{me}{spam_folders}, [ 'INBOX.$spam', 'INBOX.$suspicious' ], 'the folders given are kept' );

    foreach my $bad ( q{it's}, '100%', "two\nlines" ) {
        like( exception { $recipe->validate( %BASE, names => { me => { %account, spam_folders => [$bad] } } ) }, qr{spam_folders}, 'a name that breaks a cron line or a shell word is refused' );
    }
};

subtest 'local_resolver is on where the guest has a public address, unless the operator says otherwise' => sub {
    my %names = ( names => { me => { password => 'x', gecos => 'Me' } } );
    my $on    = sub { return { $recipe->enrich( $recipe->validate( %BASE, %names, @_ ) ) }->{local_resolver} };

    # Data::Validate::IP::is_public_ipv4 judges the address.  It counts the
    # documentation ranges (203.0.113.0/24 and the like) as not public, so the
    # public cases use an address that the internet really routes.
    ok( $on->( main_ip => '8.8.8.8' ), 'a public address turns it on' );
    foreach my $private (qw{10.1.2.3 172.16.0.9 192.168.1.5 100.64.0.1 100.127.255.254 127.0.0.1 169.254.1.1 224.0.0.1 ::1 not-an-address}) {
        ok( !$on->( main_ip => $private ), "$private does not" );
    }
    ok( !$on->(), 'a guest with no address does not' );
    ok( !$on->( main_ip => '8.8.8.8',  local_resolver => 0 ), 'false turns it off on a public guest' );
    ok( $on->( main_ip  => '10.1.2.3', local_resolver => 1 ), 'and true turns it on for a private one' );
};

subtest 'the cron job trains each account with its own spam folders' => sub {
    my %opts = $recipe->validate(
        %BASE,
        script_dir => '/scripts',
        names      => {
            me  => { password => 'x', gecos => 'Me', spam_folders => ['INBOX.$spam'] },
            you => { password => 'x', gecos => 'You' },
        },
    );
    my $cron   = $recipe->render_raw( 'files/mail.cron.tt', $recipe->enrich(%opts) );
    my $line   = qr{^21[ ]2[ ]\*[ ]\*[ ]\*[ ]root[ ]/scripts/sa_train_amavis[ ]}m;
    my $folder = qr{--spam-folder[ ]'INBOX[.][\$]spam'[ ]};
    my $home   = qr{/mail/\Q$BASE{domain}\E};
    like( $cron, qr{$line$folder$home/me/Maildir\n}m, 'one line has the folder of the account, with its dollar sign as it is' ) or diag $cron;
    like( $cron, qr{$line$home/you/Maildir\n}m,       'and an account with none passes none' )                                  or diag $cron;

    my $target  = $recipe->render_raw( 'mail.tt', $recipe->enrich(%opts) );
    my $doubled = qr{--spam-folder[ ]'INBOX[.][\$][\$]spam'[ ]};
    like( $target, qr{^/scripts/sa_train_amavis[ ]$doubled}m, 'the build seeds the database, with the dollar sign doubled for make' ) or diag $target;
};

Test::NoWarnings::had_no_warnings();

subtest 'mailbox_aliases maps the names that other clients make to the flagged folders' => sub {
    my %default = $recipe->validate(%BASE);
    is_deeply(
        $default{mailbox_aliases},
        {
            'Junk'             => 'Junk Email',
            'Sent'             => 'Sent Items',
            'Trash'            => 'Deleted Items',
            'Sent Messages'    => 'Sent Items',
            'Deleted Messages' => 'Deleted Items',
        },
        'the five names of Thunderbird, Roundcube and Apple Mail are there by default'
    );

    my %more = $recipe->validate( %BASE, mailbox_aliases => { Gesendet => 'Sent Items', Junk => 'Spam Box' } );
    is( $more{mailbox_aliases}{Gesendet}, 'Sent Items',    'a name that is added is kept' );
    is( $more{mailbox_aliases}{Junk},     'Spam Box',      'a default name can change its target' );
    is( $more{mailbox_aliases}{Trash},    'Deleted Items', 'and the other defaults stay' );

    foreach my $bad ( [ q{a.b} => 'Sent Items' ], [ 'Sent' => q{a'b} ], [ 'a/b' => 'Sent Items' ], [ 'Sent' => q{$x} ], [ 'Foo#Bar' => 'Sent Items' ], [ 'Sent' => 'Foo#Bar' ], [ '<file' => 'Sent Items' ], [ 'Sent' => '<file' ], [ ' Foo' => 'Sent Items' ], [ 'Foo ' => 'Sent Items' ], [ 'Sent' => ' Foo' ], [ 'Sent' => "Foo\t" ] ) {
        like( exception { $recipe->validate( %BASE, mailbox_aliases => { $bad->[0] => $bad->[1] } ) }, qr{mailbox_aliases}, "a name that a shell or a Maildir cannot hold is refused: $bad->[0] => $bad->[1]" );
    }

    foreach my $bad ( [ 'Old*' => 'Sent Items' ], [ 'Old?' => 'Sent Items' ], [ 'Sent' => 'Sent*' ], [ 'Sent' => 'Sent?' ] ) {
        like( exception { $recipe->validate( %BASE, mailbox_aliases => { $bad->[0] => $bad->[1] } ) }, qr{mailbox_aliases}, "a name that doveadm reads as a wildcard is refused: $bad->[0] => $bad->[1]" );
    }
};

subtest 'the dovecot configuration declares the four folders and one alias pair for each alias' => sub {
    my %opts = $recipe->validate(%BASE);
    my $conf = $recipe->render_raw( q{files/mail.dovecot.tt}, $recipe->enrich(%opts) );
    like( $conf, qr/^mail_plugins[ ]=[ ].*\bmailbox_alias\b/m, 'the plugin is loaded' );
    my %use = (
        'Sent Items'    => '\\Sent',
        'Deleted Items' => '\\Trash',
        'Junk Email'    => '\\Junk',
        'Drafts'        => '\\Drafts',
    );
    foreach my $name ( sort keys %use ) {
        my $quoted  = $name =~ m/[ ]/ ? qq{"$name"} : $name;
        my $head    = qr/mailbox[ ]\Q$quoted\E[ ]\{/;
        my $special = qr/\s+special_use[ ]=[ ]\Q$use{$name}\E/;
        my $auto    = qr/\s+auto[ ]=[ ]subscribe/;
        like( $conf, qr/$head$special$auto/, "$name is declared with its special use, subscribed" );
    }
    my @old = $conf =~ m/^\s*mailbox_alias_old\d*\s*=\s*(.+?)\s*$/mg;
    my @new = $conf =~ m/^\s*mailbox_alias_new\d*\s*=\s*(.+?)\s*$/mg;
    is_deeply( \@new, [ sort keys %{ $opts{mailbox_aliases} } ],                                    'each alias is a new name, because the plugin makes the new name the link' );
    is_deeply( \@old, [ map { $opts{mailbox_aliases}{$_} } sort keys %{ $opts{mailbox_aliases} } ], 'and each target is the old name, the real folder, in the same order' );
    like( $conf, qr/^\s*mailbox_alias_old\s*=/m,  'the first pair has no number' );
    like( $conf, qr/^\s*mailbox_alias_old5\s*=/m, 'and the fifth is numbered 5' );
};

subtest 'the build merges a real folder under an alias name, in every account and in the catchall' => sub {
    my %names    = ( names => { someuser => { password => 'x', gecos => 'Some User' } }, script_dir => '/nonexistent' );
    my $fragment = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich( $recipe->validate( %BASE, %names ) ) );
    my @merge    = grep { m/\Aif[ ]test[ ]-d[ ].*doveadm[ ]move/ } split m/\n/, $fragment;

    # Run as make would hand them to the shell, with a doveadm that writes down
    # what it was asked, and a store where the account and the catchall each
    # came back with a real .Junk, and the account has Trash as a link.
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$dir/$_" or die "mkdir: $!" for qw{bin store store/someuser store/someuser/Maildir store/someuser/Maildir/.Junk store/catchall store/catchall/Maildir store/catchall/Maildir/.Junk};
    symlink '.Deleted Items', "$dir/store/someuser/Maildir/.Trash" or die "symlink: $!";
    File::Slurper::Temp::write_text( "$dir/bin/doveadm", qq{#!/bin/sh\necho "\$*" >> "$dir/asked"\n} );
    chmod 0755, "$dir/bin/doveadm" or die "chmod: $!";
    foreach my $line (@merge) {
        my $command = $line =~ s/\$\$/\$/gr =~ s{/mail/mail[.]test[.]test}{$dir/store}gr;
        my $out;
        IPC::Run3::run3( [ 'bash', '-c', "PATH='$dir/bin':\$PATH; $command" ], \undef, \$out, \$out );
        is( $? >> 8, 0, 'the line succeeds' ) or diag $out;
    }
    my $asked = -e "$dir/asked" ? File::Slurper::read_text("$dir/asked") : q{};
    is( $asked, join( q{}, map { "move -u $_\@mail.test.test Junk Email mailbox Junk all\nmailbox delete -u $_\@mail.test.test Junk\n" } qw{someuser catchall} ), 'the messages of each .Junk move into Junk Email, and the empty folder goes, in the catchall too' )
      or diag $fragment;

    # A domain with no names of its own still has a catchall to merge.
    my $alone = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich( $recipe->validate( %BASE, script_dir => '/nonexistent' ) ) );
    ok( ( grep { m/\Aif[ ]test[ ]-d[ ].*catchall.*doveadm[ ]move/ } split m/\n/, $alone ), 'and a domain with no names merges the folders of its catchall' ) or diag $alone;
};

subtest 'a backtick in a folder name is refused, and the shell never expands a name it renders' => sub {
    like( exception { $recipe->validate( %BASE, mailbox_aliases => { q{Old`date`Mail} => 'Sent Items' } ) }, qr{mailbox_aliases}, 'an alias with a backtick is refused' );
    like( exception { $recipe->validate( %BASE, mailbox_aliases => { 'Sent'           => q{a`date`b} } ) },  qr{mailbox_aliases}, 'and so is a target with one' );

    my %names    = ( names => { someuser => { password => 'x', gecos => 'Some User' } }, script_dir => '/nonexistent' );
    my $fragment = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich( $recipe->validate( %BASE, %names ) ) );
    my @echoes   = $fragment =~ m/&&[ ]echo[ ](.*?);[ ]fi$/mg;
    ok( scalar @echoes, 'the build says which folders it merged' );
    for my $echo (@echoes) { unlike( $echo, qr/\A"/, 'and the message is not in double quotes, where a backtick runs' ); }
};

subtest 'mailboxes takes the rule of a folder name' => sub {
    foreach my $bad ( qw{a$b a`date`b a;b/c a.b}, q{a'b} ) {
        like( exception { $recipe->validate( %BASE, names => { someuser => { password => 'x', gecos => 'Some User', mailboxes => [$bad] } } ) }, qr{mailboxes}, "a mailbox that a shell or a Maildir cannot hold is refused: $bad" );
    }
    my %ok = $recipe->validate( %BASE, script_dir => '/nonexistent', names => { someuser => { password => 'x', gecos => 'Some User', mailboxes => [ 'Archive', 'Old Mail' ] } } );
    is_deeply( $ok{names}{someuser}{mailboxes}, [ 'Archive', 'Old Mail' ], 'a plain name and a name with a space are kept' );

    my $fragment = $recipe->render_raw( 'ubuntu/mail.tt', $recipe->enrich(%ok) );
    my $status   = qr/messages[ ]'Old[ ]Mail'[ ]/;
    my $create   = qr/mailbox[ ]create[ ].*[ ]'Old[ ]Mail'$/m;
    like( $fragment, qr/$status.*$create/m, 'and the template quotes the name, so the space stays one word' );
};

done_testing();
