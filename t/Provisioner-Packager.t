#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Packager.t - the packager of a family of distributions: found by
name, and the only thing that knows what first boot does with packages

=cut

use Test::More;
use Test::Fatal;
use Test::MockModule qw{strict};
use Test::NoWarnings qw{had_no_warnings};
use File::Slurper();

use FindBin;
use FindBin::libs;

use_ok('Provisioner::Packager');
use Provisioner::Cookbook();

# A packager of another family, which needs no file of its own.
{

    package Provisioner::Packager::Fake;
    use parent -norequire, 'Provisioner::Packager';
    sub merge              { my ( $class, @sources ) = @_; return @sources }
    sub first_boot_files   { return { path => '/etc/fake/sources', permissions => '0644', content => "fake\n" } }
    sub answers            { return () }
    sub cloud_init_modules { return qw{cc_fake_repos} }
}
local $INC{'Provisioner/Packager/Fake.pm'} = __FILE__;

subtest 'named: the class for the answer of a distro recipe' => sub {
    is( Provisioner::Packager->named('deb'),  'Provisioner::Packager::Deb',  'deb is the Debian family' );
    is( Provisioner::Packager->named('fake'), 'Provisioner::Packager::Fake', 'and any other family has its own' );

    like( exception { Provisioner::Packager->named(undef) },    qr/No[ ]packager[ ]named/,                       'a distribution that names none is refused' );
    like( exception { Provisioner::Packager->named('../x') },   qr/is[ ]not[ ]the[ ]name[ ]of[ ]a[ ]packager/,   'and so is a name that is not one' );
    like( exception { Provisioner::Packager->named('nosuch') }, qr/There[ ]is[ ]no[ ]packager[ ]for[ ]'nosuch'/, 'and one with no class, by name' );
};

subtest 'a packager that does not answer says so' => sub {
    {

        package Provisioner::Packager::Mute;
        use parent -norequire, 'Provisioner::Packager';
    }
    foreach my $method (qw{merge first_boot_files answers cloud_init_modules}) {
        like( exception { Provisioner::Packager::Mute->$method() }, qr/Provisioner::Packager::Mute[ ]does[ ]not[ ]say[ ]$method/, "$method, naming the packager" );
    }
};

subtest 'the Debian family' => sub {
    my $deb = Provisioner::Packager->named('deb');
    is_deeply( [ $deb->answers( 'a b c', 'd e f', 'a b c' ) ],     [ 'a b c', 'd e f' ], 'the answers once each' );
    is_deeply( [ $deb->cloud_init_modules ],                       ['cc_apt_configure'], 'and the module that applies them' );
    is_deeply( [ $deb->first_boot_files( domain => 'one.test' ) ], [],                   'no sources and no conflicts is no files' );
    my ($pin) = $deb->first_boot_files( domain => 'one.test', conflicts => [qw{ntp apache2 ntp}] );
    like( $pin->{content}, qr/^Package:[ ]apache2[ ]ntp$/m, 'a conflict is pinned out, once, whatever order it came in' );
};

# The distro recipe asks its packager, so a distribution of another family needs
# only a packager, and the generator and bin/provision never change for it.
subtest 'the distro recipe goes through its packager' => sub {
    my $ubuntu = Test::MockModule->new('Provisioner::Recipe::ubuntu');
    $ubuntu->redefine( packager => sub { 'fake' } );
    my $distro = Provisioner::Cookbook->load('ubuntu');

    is_deeply(
        [ $distro->rerun_modules ],
        [qw{cc_bootcmd cc_write_files cc_fake_repos cc_package_update_upgrade_install cc_users_groups}],
        'what a domain added to a running guest runs again comes from the packager'
    );
};

subtest 'the generator and bin/provision name no packager' => sub {
    foreach my $program (qw{bin/new_config bin/provision}) {
        my $text = File::Slurper::read_text("$FindBin::Bin/../$program");
        unlike( $text, qr/\bapt\b|apt-get|debconf|dpkg|cc_apt_|keyring|deb822/i, "$program leaves packages to the packager" );
    }
};

had_no_warnings();
done_testing();
