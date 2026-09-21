#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/skills-scratch-config.t - the provisioning-recipes scratch configuration: what
it builds, and what it refuses to take from the installation

=cut

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/scratch_config")
  or BAIL_OUT('the scratch_config script does not load');

# An installation shaped like the real one: a _base naming a credential, a
# recipe set every guest would inherit, and a domain of its own.
sub installation {
    my (%extra) = @_;

    my $source = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_binary(
        "$source/recipes.yaml",
        YAML::XS::Dump(
            {
                _base => {
                    _global => {
                        registrar   => { type => 'easydns', key => 'secret:group/entry/field' },
                        libdir      => ['/opt/vendor-recipes'],
                        basedir     => '/bogus',
                        admin_user  => 'operator',
                        admin_gecos => 'The Operator',
                        admin_email => 'operator@test.test',
                        gateway     => '192.0.2.254',
                        resolvers   => ['192.0.2.254'],
                        ip_pool     => { cidr => '192.0.2.0/26' },
                        %extra,
                    },
                    letsencrypt => {},
                    auditd      => {},
                },
                'theirs.test.test' => { ntp => {} },
            }
        )
    );

    return $source;
}

sub scratch {
    my (%opts) = @_;

    my $source = delete $opts{source} // installation( mirror => 'http://mirror.test/ubuntu' );
    my $dir    = tempdir( CLEANUP => 1 );

    Trog::Skill::ScratchConfig::build( $source, $dir, %opts );
    return ( YAML::XS::Load( File::Slurper::read_binary("$dir/recipes.yaml") ), $dir );
}

# bin/new_config refuses to build a guest with nobody authorized on it, so a
# scratch configuration has to end up with keys whatever the installation has.
subtest 'somebody is authorized on a scratch guest either way' => sub {
    my $operator = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAoperatorskey operator\n";

    my $source = installation();
    File::Slurper::Temp::write_text( "$source/admin_authorized_keys", $operator );

    my ( undef, $dir ) = scratch( source => $source );
    is( File::Slurper::read_text("$dir/admin_authorized_keys"), $operator, 'the installation keys are copied as they stand' );

    # And an installation nobody has seeded yet still produces a configuration a
    # guest can be built from.  Nothing is lost by the stand-in: what reaches a
    # scratch guest is the domain key, which the ubuntu recipe authorizes on
    # every guest whatever else is in the list.
    my ( undef, $bare ) = scratch( source => installation() );
    like( File::Slurper::read_text("$bare/admin_authorized_keys"), qr/\Assh-/, 'and a throwaway one is minted when it has none' );

    # write_ssh_keypair sets no mode, so without a chmod of our own the umask
    # decides and the private half is readable by anyone on this machine.
    my $mode = ( stat("$bare/scratch_admin_key") )[2] & oct('7777');
    is( sprintf( '%04o', $mode ), '0600', 'with the private half of it kept to ourselves' );
};

subtest 'the base is built here rather than taken from the installation' => sub {
    my ($recipes) = scratch();

    is_deeply( [ sort keys %$recipes ],              ['_base'],   'no domain of the installation comes across' );
    is_deeply( [ sort keys %{ $recipes->{_base} } ], ['_global'], 'and none of its recipe set either' );

    # A guest asked for two recipes was installing a certificate authority and a
    # DNS server, because the installation's _base said every guest gets them.
    ok( !exists $recipes->{_base}{letsencrypt}, 'so a scratch guest gets what new_guest named' );
    ok( !exists $recipes->{_base}{auditd},      'and nothing the fleet happens to give its own' );
};

# The settings of the installation are not a credential and a guest cannot be
# built without them, so they come across while the recipes beside them do not.
subtest 'a scratch guest is configured as a real one is' => sub {
    my ($recipes) = scratch();
    my $global = $recipes->{_base}{_global};

    is( $global->{admin_user}, 'operator',    'the administrator of the installation administers a scratch guest too' );
    is( $global->{gateway},    '192.0.2.254', 'it reaches the network the same way' );
    is_deeply( $global->{ip_pool}, { cidr => '192.0.2.0/26' }, 'and draws from the same pool, so it cannot take an address a real guest has' );
};

subtest 'nothing it cannot hold a credential for comes with it' => sub {
    my ( $recipes, $dir ) = scratch();

    # The whole reason the store is thrown away: this harness has no way into the
    # real one.  Copying a _base that names secrets meant every scratch guest
    # carried a registrar whose credentials were invented.
    my $yaml = File::Slurper::read_binary("$dir/recipes.yaml");
    unlike( $yaml, qr/secret:/, 'no secret reference survives into the scratch configuration' );
    ok( !exists $recipes->{_base}{_global}{registrar}, 'the registrar in particular does not' );
    ok( !exists $recipes->{_base}{_global}{libdir},    'nor the vendor recipe directories' );
};

subtest 'its data source is its own' => sub {
    my ( $recipes, $dir ) = scratch();

    is( $recipes->{_base}{_global}{data_source}, "$dir/data", 'inside the scratch directory' );
    ok( -d "$dir/data", 'and the directory is there to be read' );
};

subtest 'the mirror is carried over, being the one thing that is not a credential' => sub {
    my ($recipes) = scratch();
    is( $recipes->{_base}{_global}{mirror}, 'http://mirror.test/ubuntu', 'so a scratch build is no slower than a real one' );

    # And nothing invented when the installation has none.
    my ($bare) = scratch( source => installation() );
    ok( !exists $bare->{_base}{_global}{mirror}, 'and none conjured when there is none to take' );
};

subtest 'CPAN suites and a fetch cache, when they are asked for' => sub {
    my ($recipes) = scratch();
    ok( !exists $recipes->{_base}{_global}{cpan_notest}, 'suites skipped by default, as on a real guest' );
    ok( !exists $recipes->{_base}{_global}{cache},       'and nothing provisions through a cache unasked' );

    ($recipes) = scratch( cpan_tests => 1 );
    is( $recipes->{_base}{_global}{cpan_notest}, 0, '--cpan-tests turns the suites on' );

    ($recipes) = scratch( cache => 'fetchcache.test' );
    is( $recipes->{_base}{_global}{cache}, 'fetchcache.test', 'and --cache names it in _base, for every guest' );

    ($recipes) = scratch( cache => 'fetchcache.test', cpan_tests => 1 );
    is( $recipes->{_base}{_global}{cache},       'fetchcache.test', 'both together: the cache' );
    is( $recipes->{_base}{_global}{cpan_notest}, 0,                 'and the suites' );
};

done_testing();
