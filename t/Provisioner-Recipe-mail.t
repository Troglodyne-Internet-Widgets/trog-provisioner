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
};

subtest 'a domain with an edge sends its mail through the relay there' => sub {
    is_deeply(
        [ $recipe->grants( 'mail.test.test', edge => 'edge.test.test' ) ],
        [ { recipe => 'edge', guest => 'edge.test.test', client => 'mail.test.test', service => 'mail' } ],
        'the edge issues it a login on its relay'
    );
    is_deeply( [ $recipe->grants('mail.test.test') ], [], 'and a domain with no edge holds none' );

    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return { guests => '192.0.2.5' } } );
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { return {} } );

    my %opts = $recipe->enrich( $recipe->validate( %BASE, edge => 'edge.test.test' ) );
    is_deeply( $opts{edge_relay}, { address => '192.0.2.5', port => 2587, password => '/etc/postfix/edge/mail.test.test.password' }, 'at the address where the guests reach the edge, on its relay port, with the password that it issued' );

    like(
        exception { $recipe->enrich( $recipe->validate( %BASE, edge => 'edge.test.test', relay => { host => 'relay.test.test', port => 25 } ) ) },
        qr/both[ ]a[ ]relay[ ]and[ ]an[ ]edge/,
        'a relay and an edge together are refused, because they disagree about where the mail goes'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing();
