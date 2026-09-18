#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Recipe-claude.t - the plugins claude's settings enable, and where they come from

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use Cpanel::JSON::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my %BASE = (
    domain      => 'bot.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'doge',
    script_dir  => '/root/bin',
    main_ip     => '192.168.1.9',
);

# The rendered settings, as JSON, for a guest running these modules.
sub settings_for {
    my (@modules) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $r->generate_files( $dir, %BASE, modules => [@modules] );

    my $text = do { local ( @ARGV, $/ ) = "$dir/claude.settings.json"; <> }
      // q{};

    # Assigned rather than returned straight out of the eval: the profile wants
    # an eval whose value somebody looks at, and both callers here do.
    my $conf = eval { Cpanel::JSON::XS::decode_json($text) };
    return ( $text, $conf );
}

# A plugin whose marketplace this same file never declares loads nothing, and
# says nothing about it -- so the only place the mistake shows is here.  Asked
# of several guests rather than one, because the two ways in are different: the
# name is wrong on every guest, while the gating is only wrong on a guest
# missing one of the modules a marketplace is conditional on.
my %CASES = (
    'a guest with perl and perllsp' => [qw{perl perllsp claude}],
    'a guest with perl alone'       => [qw{perl claude}],
    'a guest with neither'          => [qw{claude}],
);

foreach my $what ( sort keys %CASES ) {
    subtest "every plugin enabled for $what comes from a marketplace it declares" => sub {
        my ( $text, $conf ) = settings_for( @{ $CASES{$what} } );

        ok( $conf, 'the settings render as valid JSON' ) or diag $text;
        return unless $conf;

        my %declared = map { $_ => 1 } keys %{ $conf->{extraKnownMarketplaces} // {} };
        my @orphans  = grep {
            my $at     = index( $_, '@' );
            my $market = $at >= 0 ? substr( $_, $at + 1 ) : q{};
            !$market || !$declared{$market}
        } keys %{ $conf->{enabledPlugins} // {} };

        is_deeply( \@orphans, [], 'no enabled plugin names a marketplace that is not there' )
          or diag 'declared: ' . join( ', ', sort keys %declared );
    };
}

# The one plugin no gate covers, so a guest that runs this recipe and nothing
# else still gets it.  Named for what it is published as: the id shipped here
# was perl-sloppin@Troglodyne-Internet-Widgets, which nothing publishes.
subtest 'the troglodyne plugin is enabled whatever else the guest runs' => sub {
    my ( undef, $conf ) = settings_for(qw{claude});

    ok( $conf,                                                       'the settings render as valid JSON' ) or return;
    ok( $conf->{enabledPlugins}{'perl-slop@troglodyne-marketplace'}, 'perl-slop is enabled under the name it is published as' )
      or diag 'enabled: ' . join( ', ', sort keys %{ $conf->{enabledPlugins} // {} } );
};

Test::NoWarnings::had_no_warnings();

done_testing();
