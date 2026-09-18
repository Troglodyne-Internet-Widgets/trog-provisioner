package Trog::Secrets;

#ABSTRACT: The KeePass database: what a configuration asks it for, and what it answers.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::KeePass::KDBX();
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
        my %values = Trog::Secrets->lookup($file, Trog::Credentials->prompt('Enter password:', 'keepass'), %needed);
        Trog::Secrets->apply($config, %values);
    }

=head1 DESCRIPTION

A recipe configuration must not carry a password.  It carries a reference that
says where the password is:

    registrar:
        key: "secret:troglodyne/easydns_token/password"

C<needed> finds each of those notes, at any depth.  C<lookup> resolves them
against a KeePass database.  C<apply> puts the answers back where the notes
were.  C<create> makes a new database, and only a test harness uses it.

=head2 The syntax of a reference

A reference is C<secret:GROUP/ENTRY/FIELD>.  GROUP is a group in the database,
ENTRY is an entry in that group, and FIELD is a field on that entry.  FIELD must
be C<password> or C<username>, because the database drops other fields when it
saves.

=head1 CLASS METHODS

=head2 needed($config)

Returns each C<secret:> reference in C<$config> as a hash.  A key is the place
of the reference, and its value is the reference.  Returns an empty list if
C<$config> is not a hash reference.

The place is the path of hash keys and array indices to the reference, joined
with C</>.  C<apply> reads this path to find the place again.

=cut

sub needed {
    my ( $class, $config ) = @_;
    return () unless ref $config eq 'HASH';

    my %found;
    my @nodes = values %$config;
    my @paths = keys %$config;

    # Breadth first with a queue, not recursion, because a configuration can
    # nest to any depth.
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

        # No other type that YAML gives can be a reference.
    }

    return %found;
}

=head2 lookup($file, $password, %needed)

Resolves each reference in C<%needed> against the database in C<$file>.
C<%needed> maps a key to a reference, as the return value of C<needed> does.
Returns a hash of the same keys to their values.

Dies if C<%needed> is empty, or if the database cannot be opened or unlocked.
Also dies with the name of a group, entry or field that is not there.  Without
this, a reference that resolves to nothing gets to a guest as an empty password.

=cut

sub lookup {
    my ( $class, $file, $password, %needed ) = @_;

    die "Nothing to look up.\n" unless %needed;

    # Grouped so that the database is searched once for each group, not once
    # for each reference.
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
              unless length $entry->{ $want->{field} };    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a secret of "0" is still a secret

            $values{ $want->{path} } = $entry->{ $want->{field} };
        }
    }
    $kdbx->lock();

    return %values;
}

=head2 apply($config, %values)

Puts each value in C<%values>, which is what C<lookup> returns, back where its
reference was in C<$config>.  Returns C<$config>.

Dies if a path does not lead back to a place in C<$config>.

=cut

sub apply {
    my ( $class, $config, %values ) = @_;

    foreach my $path ( keys %values ) {
        my @steps = split( m{/}, $path );
        my $leaf  = pop @steps;

        # Walked, never built into a string and evaluated, because the path
        # comes from a configuration file.
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

=head2 create($file, $password, %value_by_ref)

Makes a new database in C<$file> that holds a value for each reference in
C<%value_by_ref>.  Returns C<$file>.

Use it to make a throwaway store to provision against.  The caller chooses the
values.  Do not use it on a real store, because it replaces the whole file.

=cut

sub create {
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

Returns a hash of each reference in C<%generator_by_ref> to its value.  A
generator is a coderef.  If a reference holds nothing, this calls its generator
and keeps the result in the database.  A reference that holds a value keeps
that value, and its generator is not called.  Returns an empty list if
C<%generator_by_ref> is empty.

Use it for a secret that the provisioner owns, such as a signing key.  The
secret stays the same when the guest is rebuilt.  It is never written into the
domain directory, where the data recipe would put it into each backup.

Dies if the database cannot be opened or unlocked, or if a generator returns a
false value.  Also dies if the database did not keep a new value.

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

        if ( $entry && length $entry->{$field} ) {    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a secret of "0" is still a secret
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

    # Save only when there is something new, because a save rewrites the store
    # that every other domain also uses.
    return %values unless %made;

    $kdbx->save_db( $file, $password );
    $kdbx->lock();
    $class->_confirm_kept( $file, $password, \%values, \%made );

    return %values;
}

=head2 _confirm_kept($file, $password, \%values, \%made)

Opens C<$file> again and makes sure that it holds the value in C<%values> for
each reference in C<%made>.  Returns 1.  C<remember> calls it after a save.

It catches a field that the database drops when it saves.  See
L</The syntax of a reference>.  Without this check, a secret that must stay the
same changes on each provision.

Dies if the database cannot be opened or unlocked, or if a reference did not
keep its value.

=cut

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

=head2 replace($file, $password, %value_by_ref)

Sets each reference in C<%value_by_ref> to its value, in the database that is
already in C<$file>.  It adds a group or entry that is not there.  Returns 1, or
0 if C<%value_by_ref> is empty.

Dies if the database cannot be opened or unlocked.

C<create> makes a new database that holds only what it gets.  This sub opens
the store, sets the fields that you name, and does not change other secrets.

C<remember> keeps a value that is already there.  This sub replaces it.  Use it
for a value that changes on each provision, such as a guest key.

=cut

sub replace {
    my ( $class, $file, $password, %value_by_ref ) = @_;

    return 0 unless %value_by_ref;

    my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
      or die "Could not open $file\n";
    $kdbx->unlock() or die "Could not unlock $file\n";

    foreach my $ref ( sort keys %value_by_ref ) {
        my ( $group, $title, $field ) = $class->parse($ref);

        my $g     = $kdbx->find_group( { title => $group } ) // $kdbx->add_group( { title => $group } );
        my $entry = $kdbx->find_entry( { group => $g->{gid}, title => $title } ) // $kdbx->add_entry( { group => $g->{gid}, title => $title } );

        $entry->{$field} = $value_by_ref{$ref};
    }

    $kdbx->save_db( $file, $password );
    $kdbx->lock();
    return 1;
}

=head2 parse($reference)

Returns the group, entry and field that C<$reference> names, as a list.

Dies if C<$reference> does not start with C<secret:>, or if it does not name all
three parts.

=cut

sub parse {
    my ( $class, $reference ) = @_;

    die "Malformed secret '" . ( $reference // '' ) . "': must start with secret:\n"
      unless defined $reference && index( $reference, 'secret:' ) == 0;

    my ( $group, $title, $field ) = split( m{/}, substr( $reference, length 'secret:' ) );
    die "Malformed secret '$reference': wanted secret:group/entry/field\n"
      unless $group && $title && $field;

    return ( $group, $title, $field );
}

=head1 SEE ALSO

L<File::KeePass::KDBX>

=cut

1;
