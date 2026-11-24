#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

=head1 NAME

t/Provisioner-Recipe-grafanalynis.t - the Lynis dashboard reads the fields that
its processor makes, and marks a report stale at the age configured

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::NoWarnings qw{had_no_warnings};
use File::Temp       qw{tempdir};
use File::Which      qw{which};
use File::Slurper();
use File::Slurper::Temp();
use Cpanel::JSON::XS();
use IPC::Run3();

use FindBin::libs;

use Provisioner::Cookbook();

my %G = (
    domain      => 'logs.test.test',
    install_dir => '/bogus',
    script_dir  => '/bogus/bin',
    admin_user  => 'admin',
);

sub recipe {
    return Provisioner::Cookbook->load( 'grafanalynis', distro => 'ubuntu' )->new(
        template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir      => tempdir( CLEANUP => 1 ),
        distro          => 'ubuntu',
        target_packager => 'deb',
    );
}

# The files the recipe generates for %opts, in a directory of their own.
sub generated {
    my (%opts) = @_;
    my $r      = recipe();
    my $dir    = tempdir( CLEANUP => 1 );
    $r->generate_files( $dir, $r->validated( %G, %opts ) );
    return $dir;
}

sub dashboard {
    my ($dir) = @_;
    my $json = Cpanel::JSON::XS->new->decode( File::Slurper::read_text("$dir/grafanalynis_dashboard.json") );
    return ( $json, { map { $_->{title} => $_ } @{ $json->{panels} } } );
}

subtest 'required_recipes' => sub {
    my %required = recipe()->required_recipes();
    is_deeply( [ sort keys %required ],          ['grafanasyslog'], 'it needs grafanasyslog, which puts the syslog stream in influxdb, and not lynis, which runs on the guests' );
    is_deeply( { $required{grafanasyslog}->() }, {},                'and asks it for nothing' );
};

subtest 'args' => sub {
    my %opts = recipe()->validate(%G);
    is( $opts{stale_after_hours}, 26,         'a report is stale after 26 hours by default, a day and a margin' );
    is( $opts{datasource},        'InfluxDB', 'and the dashboard reads the datasource of grafana' );

    is( { recipe()->validate( %G, stale_after_hours => 25 ) }->{stale_after_hours}, 25, 'a day and an hour is accepted' );
    like( exception { recipe()->validate( %G, stale_after_hours => 24 ) }, qr/stale_after_hours/, 'a day is refused, because a daily audit is older than that for part of each day' );
};

subtest 'the dashboard' => sub {
    my ( $json, $panels ) = dashboard( generated() );
    is( $json->{uid}, 'lynis-audits', 'the dashboard has a uid of its own, so it does not replace another' );

    my $guests       = $panels->{'Newest audit of each guest'};
    my ($age)        = grep { $_->{matcher}{options} eq 'Hours since report' } @{ $guests->{fieldConfig}{overrides} };
    my ($thresholds) = map  { $_->{value}{steps} } grep { $_->{id} eq 'thresholds' } @{ $age->{properties} };
    is_deeply( [ map { $_->{value} } @$thresholds ], [ undef, 26 ], 'the age of a report turns red at stale_after_hours' );
    unlike( $guests->{targets}[0]{query}, qr/\$timeFilter/, 'the table of guests does not follow the time picker, so a stale guest stays in it' );

    foreach my $title ( 'Current warnings', 'Current suggestions' ) {
        like( $panels->{$title}{targets}[0]{query}, qr/time[ ]>[ ]now\(\)[ ]-[ ]26h/, "$title shows the findings of the last stale_after_hours" );
    }

    my ( undef, $later ) = dashboard( generated( stale_after_hours => 48 ) );
    ($age)        = grep { $_->{matcher}{options} eq 'Hours since report' } @{ $later->{'Newest audit of each guest'}{fieldConfig}{overrides} };
    ($thresholds) = map  { $_->{value}{steps} } grep { $_->{id} eq 'thresholds' } @{ $age->{properties} };
    is( $thresholds->[1]{value}, 48, 'and a configured age moves the threshold' );
    like( $later->{'Current warnings'}{targets}[0]{query}, qr/now\(\)[ ]-[ ]48h/, 'and the window of the findings with it' );

    my $body = File::Slurper::read_text( generated( datasource => 'Other' ) . '/grafanalynis_dashboard.json' );
    unlike( $body, qr/"InfluxDB"/, 'every panel names the configured datasource' );
};

# The processor, run by telegraf on the points that the syslog input makes of
# what lynis_audit logs.
subtest 'the processor' => sub {
    my $telegraf = which('telegraf') or plan skip_all => 'telegraf is not installed';

    my $dir      = generated();
    my $fragment = File::Slurper::read_text("$dir/grafanalynis_telegraf.conf");
    like( $fragment, qr{script[ ]=[ ]"/etc/telegraf/lynis_findings\.star"}, 'the fragment loads the script where the global fragment installs it' );
    $fragment =~ s{/etc/telegraf/lynis_findings\.star}{$dir/grafanalynis_findings.star};

    my $tag = 'syslog,facility=user,hostname=guest.test.test';
    File::Slurper::Temp::write_text(
        "$dir/points.lp",
        join(
            q{},
            map { "$_\n" } (
                qq{$tag,appname=lynis,severity=notice message="hardening_index=67 warnings=2 suggestions=48" 1700000000000000000},
                qq{$tag,appname=lynis,severity=warning message="warning KRNL-5830: Reboot of system is most likely needed" 1700000001000000000},
                qq{$tag,appname=lynis,severity=info message="suggestion PKGS-7394: Install it: now" 1700000002000000000},
                qq{$tag,appname=lynis,severity=info message="something else" 1700000003000000000},
                qq{$tag,appname=sshd,severity=notice message="hardening_index=99 warnings=0 suggestions=0" 1700000004000000000},
                qq{$tag,appname=lynis,severity=notice message="hardening_index=70 warnings=0 suggestions=1",timestamp=1699800000000000000i 1700000005000000000},
            )
        )
    );
    File::Slurper::Temp::write_text( "$dir/telegraf.conf", qq{[agent]\n  omit_hostname = true\n[[inputs.file]]\n  files = ["$dir/points.lp"]\n  data_format = "influx"\n$fragment} );

    IPC::Run3::run3( [ $telegraf, '--config', "$dir/telegraf.conf", '--test' ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'telegraf takes the configuration' ) or return diag $err;
    my @points = map { s/\A>[ ]//r } grep { m/\A>[ ]/ } split m/\n/, $out;
    is( scalar @points, 6, 'and passes every point through' ) or return diag $out;

    like( $points[0], qr/[ ,]lynis_hardening_index=67i[ ,]/,            'the summary gets the hardening index as an integer' );
    like( $points[0], qr/[ ,]lynis_warnings=2i[ ,]/,                    'and the warnings' );
    like( $points[0], qr/[ ,]lynis_suggestions=48i[ ,]/,                'and the suggestions' );
    like( $points[0], qr/[ ,]lynis_reported=1700000000i[ ,]/,           'and the time of the report in seconds' );
    like( $points[1], qr/,lynis_finding=warning,lynis_test=KRNL-5830,/, 'a warning gets its kind and test as tags' );
    ok( index( $points[1], 'lynis_text="Reboot of system is most likely needed"' ) >= 0, 'and its text as a field' ) or diag $points[1];
    like( $points[2], qr/,lynis_finding=suggestion,lynis_test=PKGS-7394,/, 'a suggestion gets its kind and test' );
    like( $points[2], qr/[ ,]lynis_text="Install[ ]it:[ ]now"/,            'and its text, whole after the first colon' );
    unlike( $points[3], qr/lynis_/, 'another line from lynis gets nothing' );
    unlike( $points[4], qr/lynis_/, 'and a line from another program that looks like a summary gets nothing' );
    like( $points[5], qr/[ ,]lynis_reported=1699800000i[ ,]/, q{and a summary that a shipper held is dated by the time of its message, not of its arrival} );
};

had_no_warnings();
done_testing();
