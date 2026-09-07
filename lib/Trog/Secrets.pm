package Trog::Secrets;

#ABSTRACT: The KeePass database: what a configuration asks it for, and what it answers.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use File::KeePass::KDBX();
use IO::Prompter();
use Trog::Credentials();
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
        my %values = Trog::Secrets->read($file, Trog::Secrets->prompt('Enter password:', 'keepass'), %needed);
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
    my ( $class, $config ) = @_;
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

        if ( $type eq 'HASH' ) {
            push @nodes, values %$node;
            push @paths, map { "$path/$_" } keys %$node;
        }
        elsif ( $type eq 'ARRAY' ) {
            push @nodes, @$node;
            push @paths, map { "$path/$_" } 0 .. $#$node;
        }
        elsif ( !$type ) {
            $found{$path} = $node if defined $node && index( $node, 'secret:' ) == 0;
        }

        # Anything else cannot be a reference.  It is YAML.
    }

    return %found;
}

=head2 prompt($message, $name)

Ask for a password, without echoing it.

Here rather than anywhere else because this is where the asking already was,
and one way of asking is better than two: L<Trog::Machine> wants the same thing
when sudo on the far side turns out to need a password.

C<$name> says which password this is, and is what makes it answerable without
asking.  A run driven by something with no terminal -- tCMS's reprovision button,
a cron -- hands its passwords in up front, and this returns one of those rather
than prompting; see L<Trog::Credentials>.  Leave the name out and it always asks,
which is what you want for something there is no name for.

=cut

sub prompt {
    my ( $class, $message, $name ) = @_;
    $message //= 'Enter password:';

    return Trog::Credentials->get($name) if defined $name && Trog::Credentials->have($name);

    # IO::Prompter and IO::Prompt fall out with each other over @ARGV unless it
    # is flattened first.
    local *ARGV = join ' ', @ARGV;    ## no critic (CompileTime)
    my $answer = IO::Prompter::prompt( $message, -echo => '*' );

    # Kept, so the next thing in this run that wants the same store is not asked
    # again.  The usual caller pipes the answer in, and a pipe answers once.
    Trog::Credentials->remember( $name, "$answer" ) if defined $name;

    return $answer;
}

=head2 read($file, $password, %needed)

Resolve references against the database, as a map of the same paths to the
values behind them.

Dies naming the group, entry or field that was asked for and is not there,
because a reference that resolves to nothing would otherwise arrive on a guest
as an empty password.

=cut

sub read {
    my ( $class, $file, $password, %needed ) = @_;

    die "Nothing to look up.\n" unless %needed;

    # Grouped so the database is walked once per group rather than once per
    # reference.
    my %by_group;
    foreach my $path ( keys %needed ) {
        my ( $group, $title, $field ) = $class->parse( $needed{$path} );
        push @{ $by_group{$group} }, { path => $path, title => $title, field => $field };
    }

    my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
      or die "Could not open $file\n";
    $kdbx->unlock() or die "Could not unlock $file\n";

    my %values;
    foreach my $group ( keys %by_group ) {
        my $g = $kdbx->find_group( { title => $group } )
          or die "No group '$group' in $file\n";

        foreach my $want ( @{ $by_group{$group} } ) {
            my $entry = $kdbx->find_entry( { group => $g->{gid}, title => $want->{title} } )
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
    my ( $class, $config, %values ) = @_;

    foreach my $path ( keys %values ) {
        my @steps = split( '/', $path );
        my $leaf  = pop @steps;

        # Walked rather than built into a string and eval'd, which is what this
        # used to do.  The path comes out of somebody's configuration, and a key
        # with a quote in it was a way to run whatever it liked.
        my $at = $config;
        foreach my $step (@steps) {
            $at = looks_like_number($step) ? $at->[$step] : $at->{$step};
            die "Could not follow '$path' back to where the secret was\n" unless ref $at;
        }

        if   ( looks_like_number($leaf) ) { $at->[$leaf] = $values{$path} }
        else                              { $at->{$leaf} = $values{$path} }
    }

    return $config;
}

=head2 write($file, $password, %value_by_ref)

Make a database holding a value for each reference given.

For building a throwaway store to provision against.  What the values should be
is the caller's business, not this module's.

=cut

sub write {
    my ( $class, $file, $password, %value_by_ref ) = @_;

    my $kdbx = File::KeePass::KDBX->new;
    $kdbx->add_group( { title => 'Root' } );

    my %groups;
    foreach my $ref ( sort keys %value_by_ref ) {
        my ( $group, $title, $field ) = $class->parse($ref);

        $groups{$group} //= $kdbx->add_group( { title => $group } );
        my $entry = $kdbx->find_entry( { group => $groups{$group}{gid}, title => $title } ) // $kdbx->add_entry( { group => $groups{$group}{gid}, title => $title } );

        $entry->{$field} = $value_by_ref{$ref};
    }

    $kdbx->save_db( $file, $password );
    return $file;
}

=head2 remember($file, $password, %generator_by_ref)

What each reference already holds, making and keeping one where it holds
nothing.  The generator is a coderef, called only when the entry is missing.

This is for a secret the provisioner owns rather than one an operator wrote
down: a signing key, a shared secret between a guest and whatever authenticates
against it.  Generated once and kept here, it survives the guest being rebuilt
without ever being written into the domain directory -- which is where the data
recipe would pick it up and carry it into every backup taken afterwards.

Dies rather than overwrite: a reference that exists is answered, never replaced.

=cut

sub remember {
    my ( $class, $file, $password, %generator_by_ref ) = @_;

    return () unless %generator_by_ref;

    my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
      or die "Could not open $file\n";
    $kdbx->unlock() or die "Could not unlock $file\n";

    my ( %values, %made );
    foreach my $ref ( sort keys %generator_by_ref ) {
        my ( $group, $title, $field ) = $class->parse($ref);

        my $g     = $kdbx->find_group( { title => $group } );
        my $entry = $g && $kdbx->find_entry( { group => $g->{gid}, title => $title } );

        if ( $entry && defined $entry->{$field} && length $entry->{$field} ) {
            $values{$ref} = $entry->{$field};
            next;
        }

        my $made = $generator_by_ref{$ref}->()
          or die "The generator for $ref produced nothing\n";

        $g     //= $kdbx->add_group( { title => $group } );
        $entry //= $kdbx->add_entry( { group => $g->{gid}, title => $title } );
        $entry->{$field} = $made;

        $values{$ref} = $made;
        $made{$ref}   = 1;
    }

    $kdbx->lock();

    # Only when there is something new to keep.  Saving rewrites the whole
    # database, and a run that read but did not add has no business doing that
    # to the file every other domain is also being provisioned out of.
    return %values unless %made;

    $kdbx->save_db( $file, $password );
    $class->_confirm_kept( $file, $password, \%values, \%made );

    return %values;
}

# What was written has to be readable, because the database keeps the fields it
# knows about and quietly drops the rest -- a reference naming anything but
# password or username stores nothing.  Left unchecked, the caller is handed the
# secret it just made, the next run finds nothing and makes another, and a
# secret that is supposed to outlive the guest rotates on every provision
# instead.  So: read it back, and say so now rather than never.
sub _confirm_kept {
    my ( $class, $file, $password, $values, $made ) = @_;

    my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
      or die "Could not re-open $file to check what was written to it\n";
    $kdbx->unlock() or die "Could not unlock $file\n";

    foreach my $ref ( sort keys %$made ) {
        my ( $group, $title, $field ) = $class->parse($ref);
        my $g     = $kdbx->find_group( { title => $group } );
        my $entry = $g && $kdbx->find_entry( { group => $g->{gid}, title => $title } );

        next if $entry && defined $entry->{$field} && $entry->{$field} eq $values->{$ref};

        $kdbx->lock();
        die "$file did not keep $ref.  A reference has to name a field the database stores,\n" . "which is password or username; '$field' is not one and was dropped on save.\n";
    }

    $kdbx->lock();
    return 1;
}

=head2 parse($reference)

The group, entry and field a reference names.

=cut

sub parse {
    my ( $class, $reference ) = @_;

    die "Malformed secret '" . ( $reference // '' ) . "': must start with secret:\n"
      unless defined $reference && index( $reference, 'secret:' ) == 0;

    my ( $group, $title, $field ) = split( '/', substr( $reference, length 'secret:' ) );
    die "Malformed secret '$reference': wanted secret:group/entry/field\n"
      unless defined $group
      && length $group
      && defined $title
      && length $title
      && defined $field
      && length $field;

    return ( $group, $title, $field );
}

=head1 SEE ALSO

L<File::KeePass::KDBX>

=cut

1;
