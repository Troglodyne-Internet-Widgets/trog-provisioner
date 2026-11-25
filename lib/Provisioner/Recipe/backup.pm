package Provisioner::Recipe::backup;

#ABSTRACT: Back up host files offsite to a backup destination.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Provisioner::Utils;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::backup

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        backup:
            targets:
                database: "/var/lib/mysql"
                mail: "/mail"
                ...
            excludes:
                database: "foobase/ barbase/"
            key_file: "path/to/key_file_in_datadir"

=head2 DESCRIPTION

Serves files on this guest to a backup destination, so that another machine can copy them offsite between provisions.
Pair it with a guest that runs L<Provisioner::Recipe::backupdestination> to automate the backups.

Each target is an rsync module that the destination can copy.
The recipe makes a target for each path in the C<remote_files> of each recipe on the guest, named for the recipe and a number, for example C<mariadb1>.
Use C<targets> to add paths that come from systems this framework does not provision.

C<excludes> maps a target to rsync exclude patterns, separated by spaces.
The recipe adds the C<remote_skip> patterns of each recipe to the target of that recipe.
Your patterns add to these and do not replace them, so an extra exclude never starts to back up a signing key.

C<key_file> is the path of a private key, relative to the data directory of the domain.
The recipe gets the public half from it, and dies with C<Could not extract pubkey from ...> when it cannot.
The public half goes into the authorized_keys of root with a forced command and no login rights.
The makefile then deletes the private half from the guest.

A connection with that key starts a read-only, chrooted rsync daemon as root, which the configuration puts on port 40404.
The daemon reads its configuration from /etc/rsyncd.$DOMAIN.conf, which the forced command names.
The configuration is not in /root, because some builds of rsync do not read a configuration from there.

The daemon logs to /var/log/rsyncd/$DOMAIN.log.
/etc/logrotate.d/rsyncd-backup rotates that log weekly and keeps 12 weeks.
Without a log file, rsyncd sends its messages down the ssh connection, and this guest keeps no record of a failed module or transfer.
Transfer logging is off, because the destination records what it asked for in /var/log/backups/$HOST.log.

The recipe installs a reboot check that holds a reboot while a destination copies the domain, which is while that rsync daemon runs.
See Reboot checks in L<Provisioner::Recipe>.

TODO: Consult the other recipes on the guest to choose the user and group that each module runs as.

=head1 METHODS

=head2 $recipe->args()

The schema of the options: C<targets>, an object from the name of a target to
its path, and C<key_file>, a string, which are both required, and
C<excludes>, an object from the name of a target to its exclude patterns.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{targets key_file}],
        properties => {
            targets  => { type => 'object' },
            key_file => { type => 'string' },
            excludes => {
                type        => 'object',
                default     => {},
                description => 'Per-target rsync exclude patterns, space separated.  Added to what the recipes themselves say must not travel; see remote_skip in Provisioner::Recipe.',
            },
        },
    );
}

=head2 $class->default_targets(%opts)

The targets that the recipes in C<$opts{modules}> ask to have backed up, in the
order of those recipes.  Each one is a hashref:

=over 4

=item * C<name> -- the recipe name and a number, as in C<mysql1>.

=item * C<path> -- a path on the guest, out of the recipe's C<remote_files>.

=item * C<skip> -- the recipe's C<remote_skip> patterns, space separated, or
the empty string.

=back

C<install_dir> and C<domain> go to each C<remote_files>.  Both this recipe and
L<Provisioner::Recipe::backupdestination> name their targets from this list, so
the rsync modules one side serves are the ones the other side asks for.

Returns the targets, as a list of hash references.  Dies when a recipe in
C<modules> cannot be loaded.

    my @targets = Provisioner::Recipe::backup->default_targets(
        modules     => [qw{mariadb}],
        install_dir => '/opt/test.test',
        domain      => 'test.test',
    );

=cut

sub default_targets {
    my ( $class, %opts ) = @_;

    my @targets;
    foreach my $module ( @{ $opts{modules} } ) {
        require "Provisioner/Recipe/$module.pm";    ## no critic (Modules::RequireBarewordIncludes) -- the recipe is named by configuration
        my $recipe = "Provisioner::Recipe::$module";
        my %files  = $recipe->remote_files( @opts{qw(install_dir domain)} );
        my $skip   = join( ' ', $recipe->remote_skip() );
        my @paths  = sort keys %files;
        push( @targets, map { { name => $module . ( $_ + 1 ), path => $paths[$_], skip => $skip } } 0 .. $#paths );
    }

    return @targets;
}

=head2 $recipe->enrich(%opts)

Adds the C<default_targets> of the recipes in C<modules> to C<targets>, where
C<targets> does not name them already, and adds the C<remote_skip> patterns of
each to C<excludes>.  Sets C<pubkey> to the public half of C<key_file>, which
it reads from the directory of C<domain> under C<data_source>.

Returns C<%opts>, with C<targets> and C<excludes> changed in place and
C<pubkey> added.  Dies with C<Could not extract pubkey from ...> when it cannot
get the public half of the key.

    my %opts = $recipe->enrich(
        modules     => [qw{mariadb}],
        install_dir => '/opt/test.test',
        domain      => 'test.test',
        data_source => '/srv/data',
        key_file    => 'backup_key',
        targets     => {},
        excludes    => {},
    );

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @defaults      = $self->default_targets(%opts);
    my %default_skips = map { $_->{skip} ? ( $_->{name} => $_->{skip} ) : () } @defaults;

    my $targets = $opts{targets};
    %$targets = ( ( map { $_->{name} => $_->{path} } @defaults ), %$targets );

    # remote_skip adds to the excludes of the operator and is never replaced
    # by them.  See DESCRIPTION.
    my $excludes = $opts{excludes};
    foreach my $target ( sort keys %default_skips ) {
        my @both = grep { $_ } ( $default_skips{$target}, $excludes->{$target} );
        $excludes->{$target} = join( ' ', @both );
    }

    my $kf = "$opts{data_source}/$opts{domain}/$opts{key_file}";

    $opts{pubkey} = Provisioner::Utils::ssh_pubkey_from_private($kf);
    die "Could not extract pubkey from $kf!" unless $opts{pubkey};

    return %opts;
}

=head2 $recipe->template_files()

The configuration of the rsync daemon, the logrotate rule of its log and the
reboot check, the same on every guest.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        "backup.rsyncd.conf.tt"  => "rsyncd.conf",
        "backup.logrotate.tt"    => "backup.logrotate",
        "backup.reboot-check.tt" => "backup-reboot-check",
    );
}

=head2 $recipe->tests()

Returns a list of the test templates that run on the guest: F<backup.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{backup.tt};
}

1;
