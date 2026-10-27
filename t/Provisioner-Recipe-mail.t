#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-mail.t - what the mail recipe accepts for its relay, and the accounts it writes

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

use Provisioner::Cookbook();

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

subtest 'a relay that is a mail relay of this installation takes every sender, with a login' => sub {
    my %config   = ( 'relay.test.test' => { mailrelay => {} }, 'web.test.test' => { nginx => {} } );
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( configuration => sub { return {%config} } );
    $cookbook->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $config{$domain} // {} } );
    $cookbook->redefine( host_of       => sub { return } );
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return { guests => '192.0.2.5' } } );

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
    is_deeply( $relayed->{sites},                          \@sites,                     'the vhost answers for both names' );
    is_deeply( $relayed->{public_names},                   { map { $_ => $_ } @sites }, 'and the relay sends both to it' );
    is_deeply( [ sort keys %{ $asked->( nginx => {} ) } ], ['sites'],                   'without a relay, mail asks nginx for the vhost alone' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
