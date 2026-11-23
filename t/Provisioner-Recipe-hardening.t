#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-hardening.t - every guest gets the kernel settings, an
operator can change one without losing the others, and modprobe refuses the
blocked modules

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use File::Temp();
use File::Slurper::Temp();
use IPC::Run3();

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => '/bogus',
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my $recipe   = Provisioner::Cookbook->load( 'hardening', distro => 'ubuntu' )->new(%PROV);
my $validate = sub { return $recipe->validate(@_) };

# A file of the recipe as bin/new_config renders it, from options that are
# already validated.
sub render {
    my ( $tt, %opts ) = @_;
    return $recipe->render_raw( "files/$tt", %opts );
}

subtest 'every distribution requires it' => sub {
    my %required = Provisioner::Cookbook->load('ubuntu')->new( template_dirs => [], output_dir => '/bogus' )->required_recipes();
    ok( exists $required{hardening}, 'so every guest has it, and no configuration names it' );
    is_deeply( { $required{hardening}->() }, {}, 'with nothing to configure' );
};

subtest 'args' => sub {
    my %opts = $validate->();
    is( $opts{sysctl}{'kernel.kptr_restrict'}, 2, 'a guest that names nothing gets each value' );
    is( scalar keys %{ $opts{sysctl} },        8, 'all eight of them' ) or diag explain $opts{sysctl};
    is_deeply( $opts{blocked_modules}, [qw{dccp sctp rds tipc usb-storage}], 'and the modules that no guest uses are blocked' );

    # The defaults are on the members, so a value that an operator names
    # replaces that value and keeps the others.
    %opts = $validate->( sysctl => { 'kernel.kptr_restrict' => 1, 'kernel.dmesg_restrict' => 1 } );
    is( $opts{sysctl}{'kernel.kptr_restrict'},  1, 'an operator changes one value' );
    is( $opts{sysctl}{'kernel.dmesg_restrict'}, 1, 'and adds another' );
    is( $opts{sysctl}{'fs.suid_dumpable'},      0, 'and keeps the rest' );

    like( exception { $validate->( sysctl          => { 'fs.suid_dumpable' => 'bogus' } ) }, qr/suid_dumpable/,   'a value that is not a number is refused' );
    like( exception { $validate->( blocked_modules => ['../bogus'] ) },                      qr/blocked_modules/, 'and so is a module name that is a path' );
};

subtest 'the sysctl file has each value' => sub {
    my %opts = $validate->( sysctl => { 'kernel.kptr_restrict' => 1 } );
    my %file = render( 'hardening.sysctl.conf.tt', %opts ) =~ m/^([[:lower:]][\w.]+)\s=\s(\S+)$/mg;
    is_deeply( \%file, $opts{sysctl}, 'one line for each key, with the value that validation gave' );
};

subtest 'modprobe refuses each blocked module' => sub {
    my ($modprobe) = grep { -e } qw{/usr/sbin/modprobe /sbin/modprobe};
    plan skip_all => 'no modprobe here' unless $modprobe;
    my %opts = $validate->();
    my $conf = File::Temp->new( SUFFIX => '.conf' );
    File::Slurper::Temp::write_text( $conf->filename, render( 'hardening.modprobe.conf.tt', %opts ) );

    # --show-depends prints what modprobe would do, and loads nothing.
    foreach my $module ( @{ $opts{blocked_modules} } ) {
        IPC::Run3::run3( [ $modprobe, '-C', $conf->filename, '--show-depends', $module ], \undef, \my $out, \my $err );
        like( $out, qr{^install[ ]/bin/false[ ]?$}m, "modprobe would run /bin/false for $module" ) or diag "$out$err";
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
