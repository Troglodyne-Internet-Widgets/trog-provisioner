package Trog::Secrets;

#ABSTRACT: The KeePass database: what a configuration asks it for, and what it answers.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use File::KeePass::KDBX();
use IO::Prompter();
use Scalar::Util qw{looks_like_number};

=head1 NAME

Trog::Secrets - the KeePass database: what a configuration asks it for, and what
it answers.

=head1 SYNOPSIS

    use Trog::Secrets();

    my $file   = '/etc/trog-provisioner/secrets.kdbx';
    my $config = YAML::XS::Load(File::Slurper::read_binary('recipes.yaml'));

    my %needed = Trog::Secrets->needed($config);
    if (%needed) {
        my %values = Trog::Secrets->read($file, Trog::Secrets->prompt, %needed);
        Trog::Secrets->apply($config, %values);
    }

=head1 DESCRIPTION

A recipe does not carry a password; it carries a note saying where one is:

    registrar:
        key: "secret:troglodyne/easydns_token/password"

C<needed> finds every one of those, wherever it is nested.  C<read> resolves
them against a KeePass database.  C<apply> puts the answers back where the notes
were.  C<write> makes a database, which is what a test harness wants and what
nothing else should.

=head2 The shape of a reference

C<secret:GROUP/ENTRY/FIELD> -- a group in the database, an entry in that group,
and a field on that entry, which is C<password> or C<username> in practice.

=head1 CLASS METHODS

=head2 needed($config)

Every C<secret:> reference in a configuration, as a map of where it was to what
it says.

Where it was is a path of keys and array indices joined with C</>, which is what
C<apply> reads to find its way back.

=cut

sub needed {
    my ($class, $config) = @_;
    return () unless ref $config eq 'HASH';

    my %found;
    my @nodes = values %$config;
    my @paths = keys %$config;

    # Breadth first with an explicit queue rather than recursion: a config is
    # arbitrarily nested and this says plainly what it is doing.
    while (@nodes) {
        my $node = shift @nodes;
        my $path = shift @paths;
        my $type = ref $node;

        if ($type eq 'HASH') {
            push @nodes, values %$node;
            push @paths, map { "$path/$_" } keys %$node;
        }
        elsif ($type eq 'ARRAY') {
            push @nodes, @$node;
            push @paths, map { "$path/$_" } 0 .. $#$node;
        }
        elsif (!$type) {
            $found{$path} = $node if defined $node && index($node, 'secret:') == 0;
        }

        # Anything else cannot be a reference.  It is YAML.
    }

    return %found;
}

=head2 prompt($message)

Ask for a password, without echoing it.

Here rather than anywhere else because this is where the asking already was,
and one way of asking is better than two: L<Trog::Machine> wants the same thing
when sudo on the far side turns out to need a password.

=cut

sub prompt {
    my ($class, $message) = @_;
    $message //= 'Enter password:';

    # IO::Prompter and IO::Prompt fall out with each other over @ARGV unless it
    # is flattened first.
    local *ARGV = join ' ', @ARGV;    ## no critic (CompileTime)
    return IO::Prompter::prompt($message, -echo => '*');
}

=head2 read($file, $password, %needed)

Resolve references against the database, as a map of the same paths to the
values behind them.

Dies naming the group, entry or field that was asked for and is not there,
because a reference that resolves to nothing would otherwise arrive on a guest
as an empty password.

=cut

sub read {
    my ($class, $file, $password, %needed) = @_;

    die "Nothing to look up.\n" unless %needed;

    # Grouped so the database is walked once per group rather than once per
    # reference.
    my %by_group;
    foreach my $path (keys %needed) {
        my ($group, $title, $field) = $class->parse($needed{$path});
        push @{ $by_group{$group} }, { path => $path, title => $title, field => $field };
    }

    my $kdbx = File::KeePass::KDBX->load_db($file, $password)
      or die "Could not open $file\n";
    $kdbx->unlock() or die "Could not unlock $file\n";

    my %values;
    foreach my $group (keys %by_group) {
        my $g = $kdbx->find_group({ title => $group })
          or die "No group '$group' in $file\n";

        foreach my $want (@{ $by_group{$group} }) {
            my $entry = $kdbx->find_entry({ group => $g->{gid}, title => $want->{title} })
              or die "No entry '$want->{title}' in group '$group' of $file\n";

            die "Entry '$want->{title}' in '$group' has no $want->{field}\n"
              unless defined $entry->{ $want->{field} } && length $entry->{ $want->{field} };

            $values{ $want->{path} } = $entry->{ $want->{field} };
        }
    }
    $kdbx->lock();

    return %values;
}

=head2 apply($config, %values)

Put the answers back where the references were.

=cut

sub apply {
    my ($class, $config, %values) = @_;

    foreach my $path (keys %values) {
        my @steps = split('/', $path);
        my $leaf  = pop @steps;

        # Walked rather than built into a string and eval'd, which is what this
        # used to do.  The path comes out of somebody's configuration, and a key
        # with a quote in it was a way to run whatever it liked.
        my $at = $config;
        foreach my $step (@steps) {
            $at = looks_like_number($step) ? $at->[$step] : $at->{$step};
            die "Could not follow '$path' back to where the secret was\n" unless ref $at;
        }

        if (looks_like_number($leaf)) { $at->[$leaf] = $values{$path} }
        else                          { $at->{$leaf} = $values{$path} }
    }

    return $config;
}

=head2 write($file, $password, %value_by_ref)

Make a database holding a value for each reference given.

For building a throwaway store to provision against.  What the values should be
is the caller's business, not this module's.

=cut

sub write {
    my ($class, $file, $password, %value_by_ref) = @_;

    my $kdbx = File::KeePass::KDBX->new;
    $kdbx->add_group({ title => 'Root' });

    my %groups;
    foreach my $ref (sort keys %value_by_ref) {
        my ($group, $title, $field) = $class->parse($ref);

        $groups{$group} //= $kdbx->add_group({ title => $group });
        my $entry = $kdbx->find_entry({ group => $groups{$group}{gid}, title => $title })
          // $kdbx->add_entry({ group => $groups{$group}{gid}, title => $title });

        $entry->{$field} = $value_by_ref{$ref};
    }

    $kdbx->save_db($file, $password);
    return $file;
}

=head2 parse($reference)

The group, entry and field a reference names.

=cut

sub parse {
    my ($class, $reference) = @_;

    die "Malformed secret '" . ($reference // '') . "': must start with secret:\n"
      unless defined $reference && index($reference, 'secret:') == 0;

    my ($group, $title, $field) = split('/', substr($reference, length 'secret:'));
    die "Malformed secret '$reference': wanted secret:group/entry/field\n"
      unless defined $group && length $group
      && defined $title && length $title
      && defined $field && length $field;

    return ($group, $title, $field);
}

=head1 SEE ALSO

L<File::KeePass::KDBX>

=cut

1;
