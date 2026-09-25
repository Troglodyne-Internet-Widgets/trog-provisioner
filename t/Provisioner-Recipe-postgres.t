#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-postgres.t - the version it installs, and its backup and restore
scripts run against stand-ins for postgres

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Path  qw{make_path};
use File::Slurper();
use File::Slurper::Temp();
use File::Basename qw{basename};
use IPC::Run3();

use FindBin::libs;

use Provisioner::Cookbook();

sub recipe {
    return Provisioner::Cookbook->load( 'postgres', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

my %BASE = (
    domain      => 'pg.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'someadmin',
    script_dir  => '/root/bin',
    main_ip     => '192.0.2.9',
);

my $DIR = tempdir( CLEANUP => 1 );
recipe()->generate_files( $DIR, %BASE );

# Stand-ins for everything the scripts run as or against postgres.  Each logs
# its arguments, and pg_dump says so when another pg_dump is running.
my $BIN = "$DIR/bin";
my $LOG = "$DIR/log";
make_path($BIN);
my %STUBS = (
    sudo       => 'shift 2; exec "$@"',
    install    => 'for last; do :; done; mkdir -p "$last"',
    pigz       => 'cat',
    pg_dumpall => ':',
    psql       => 'echo "psql $*" >> "$LOG"; case "$*" in *datistemplate*) printf "%b" "$STUB_DBS";; esac; cat > /dev/null',
    pg_restore => 'echo "pg_restore $*" >> "$LOG"',
    pg_dump    => <<'SH',
for arg; do case "$arg" in --file=*) file="${arg#--file=}";; esac; done
mkdir "$LOG.lock" 2>/dev/null || echo "overlap" >> "$LOG"
echo "pg_dump $*" >> "$LOG"
sleep 0.2
mkdir -p "$file"
rmdir "$LOG.lock" 2>/dev/null
exit 0
SH
);
foreach my $name ( keys %STUBS ) {
    File::Slurper::Temp::write_text( "$BIN/$name", "#!/bin/bash\n$STUBS{$name}\n" );
    chmod 0755, "$BIN/$name";
}

# The rendered script, with its dump directory moved somewhere this test owns.
sub run_script {
    my ( $script, $base, @args ) = @_;
    my $text = File::Slurper::read_text("$DIR/$script");
    $text =~ s{/var/backups/postgres}{$base}g;
    File::Slurper::Temp::write_text( "$DIR/run.sh", $text );
    unlink $LOG;

    local $ENV{PATH} = "$BIN:$ENV{PATH}";
    local $ENV{LOG}  = $LOG;
    IPC::Run3::run3( [ 'bash', "$DIR/run.sh", @args ], \undef, \my $out, \my $err );
    my $status = $? >> 8;
    my $log    = -e $LOG ? File::Slurper::read_text($LOG) : q{};
    return ( $status, $log, "$out$err" );
}

subtest 'the backup dumps one database at a time' => sub {
    local $ENV{STUB_DBS} = 'one\ntwo\nthree\n';
    my $base = tempdir( CLEANUP => 1 );
    my ( $status, $log, $said ) = run_script( 'postgres-backup.sh', $base );

    is( $status,                                 0, 'and finishes' )             or diag $said;
    is( scalar( () = $log =~ m/^pg_dump[ ]/mg ), 3, 'every database is dumped' ) or diag $log;
    unlike( $log, qr/^overlap$/m, 'with no two pg_dumps running at once' ) or diag $log;
};

subtest 'the backup keeps the seven newest finished dumps' => sub {
    local $ENV{STUB_DBS} = q{};
    my $base     = tempdir( CLEANUP => 1 );
    my @finished = map { "20000101-00000$_" } 0 .. 8;
    foreach my $name (@finished) {
        make_path("$base/$name");
        File::Slurper::Temp::write_text( "$base/$name/complete", q{} );
    }
    make_path("$base/20000102-000000");
    make_path("$base/19990101-000000");

    my ( $status, undef, $said ) = run_script( 'postgres-backup.sh', $base );
    is( $status, 0, 'the backup finishes' ) or diag $said;

    my @left = sort map { basename($_) } glob("$base/[0-9]*");

    my @newest = grep { -e "$base/$_/complete" && !m/\A2000/ } @left;
    is( scalar @newest, 1, 'the dump this run made is there' );
    is_deeply(
        [ grep { m/\A2000/ || m/\A1999/ } @left ],
        [ @finished[ 3 .. 8 ], '20000102-000000' ],
        'with the six finished ones before it, and an unfinished one newer than those, but nothing older'
    );
};

subtest 'the restore asks for a database whose name has a quote in it' => sub {
    local $ENV{STUB_DBS} = q{};
    my $salvage = tempdir( CLEANUP => 1 );
    make_path("$salvage/20200101-000000/o'k");
    File::Slurper::Temp::write_text( "$salvage/20200101-000000/complete", q{} );

    my ( $status, $log, $said ) = run_script( 'postgres-restore.sh', $salvage, $salvage );
    is( $status, 0, 'the restore finishes' ) or diag $said;
    like( $log, qr/datname='o''k'/,         'as a string literal with the quote doubled' ) or diag $log;
    like( $log, qr{^pg_restore[ ].*/o'k$}m, 'and restores it' )                            or diag $log;
};

subtest 'a pinned major version' => sub {
    like( recipe()->render_global( %BASE, version => 16 ), qr/^\@PG_VERSION='16';/m, 'is the one installed' );
    unlike( recipe()->render_global(%BASE), qr/^\@?PG_VERSION='/m, 'and without one the newest is looked up' );
    like( exception { recipe()->validate( %BASE, version => 'latest' ) }, qr{/version}, 'and a version that is not a number is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
