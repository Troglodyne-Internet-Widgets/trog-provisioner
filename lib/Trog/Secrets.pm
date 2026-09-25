package Trog::Secrets;

#ABSTRACT: The KeePass database: what a configuration asks it for, and what it answers.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Fcntl qw{LOCK_EX LOCK_NB};
use File::KeePass::KDBX();
use Scalar::Util qw{looks_like_number};
use Time::HiRes  qw{time sleep};

# How many seconds a writer waits for another writer to finish with the store.
our $LOCK_WAIT = 120;

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
        key: "secret:registrar/easydns_token/password"

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
        my $g = $class->_group_named( $kdbx, $group )
          or die "No group '$group' in $file\n";

        foreach my $want ( @{ $by_group{$group} } ) {
            my $entry = $class->_entry_named( $g, $want->{title} )
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
        my $entry = $class->_entry_named( $groups{$group}, $title ) // $kdbx->add_entry( { group => $groups{$group}, title => $title } );

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

    return $class->locked(
        $file,
        sub {
            my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
              or die "Could not open $file\n";
            $kdbx->unlock() or die "Could not unlock $file\n";

            my ( %values, %made );
            foreach my $ref ( sort keys %generator_by_ref ) {
                my ( $group, $title, $field ) = $class->parse($ref);

                my $g     = $class->_group_named( $kdbx, $group );
                my $entry = $g && $class->_entry_named( $g, $title );

                if ( $entry && length $entry->{$field} ) {    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a secret of "0" is still a secret
                    $values{$ref} = $entry->{$field};
                    next;
                }

                my $made = $generator_by_ref{$ref}->()
                  or die "The generator for $ref produced nothing\n";

                $g     //= $kdbx->add_group( { title => $group } );
                $entry //= $kdbx->add_entry( { group => $g, title => $title } );
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
    );
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
        my $g     = $class->_group_named( $kdbx, $group );
        my $entry = $g && $class->_entry_named( $g, $title );

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

    return $class->locked(
        $file,
        sub {
            my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
              or die "Could not open $file\n";
            $kdbx->unlock() or die "Could not unlock $file\n";

            foreach my $ref ( sort keys %value_by_ref ) {
                my ( $group, $title, $field ) = $class->parse($ref);

                my $g     = $class->_group_named( $kdbx, $group ) // $kdbx->add_group( { title => $group } );
                my $entry = $class->_entry_named( $g, $title )    // $kdbx->add_entry( { group => $g, title => $title } );

                $entry->{$field} = $value_by_ref{$ref};
            }

            $kdbx->save_db( $file, $password );
            $kdbx->lock();
            return 1;
        }
    );
}

=head2 forget($file, $password, @refs)

Removes the entry that each reference in C<@refs> names, and returns the
references it removed.  A reference whose group or entry is not there is not an
error: the point of asking is to end with it gone.

The whole entry goes, not the one field the reference names.  An entry with its
password taken out still holds a title that says what the password was for, and
that is not what somebody asking to delete a secret means.

The group stays, even when it is left empty.  A group is the operator's filing
rather than this module's, and one of them holding nothing costs nothing.

Dies if the database cannot be opened or unlocked.  Nothing is written when no
reference matched anything.

=cut

sub forget {
    my ( $class, $file, $password, @refs ) = @_;

    return () unless @refs;

    return $class->locked(
        $file,
        sub {
            my $kdbx = File::KeePass::KDBX->load_db( $file, $password )
              or die "Could not open $file\n";
            $kdbx->unlock() or die "Could not unlock $file\n";

            my @gone;
            foreach my $ref (@refs) {
                my ( $group, $title ) = $class->parse($ref);

                my $g     = $class->_group_named( $kdbx, $group ) or next;
                my $entry = $class->_entry_named( $g, $title )    or next;

                $kdbx->delete_entry( { id => $entry->{id} } );
                push( @gone, $ref );
            }

            unless (@gone) {
                $kdbx->lock();
                return ();
            }

            $kdbx->save_db( $file, $password );
            $kdbx->lock();

            return @gone;
        }
    );
}

=head2 locked($file, $work)

Runs the coderef C<$work> while this process holds the store in C<$file> for
writing, and returns what C<$work> returns, in the context of the call.  Every
sub here that saves the store calls it, around everything from its load to its
save.

A save writes the whole store, from what the writer loaded.  So two writers
that load before either saves each save what the other did not see, and the
second save throws away the change of the first.  Code outside this module that
loads and saves the store, as C<bin/regroup_secrets> does, must call this too.

The lock is an C<flock> on C<$file.lock>, beside the store, which this sub
makes if it is not there.  It is not on the store itself, because a save
replaces the store with a new file, and a lock on the old file does not stop a
writer that opens the new one.  A reader needs no lock, because a save
replaces the file whole.

Waits up to C<$Trog::Secrets::LOCK_WAIT> seconds for another writer.  Dies if
the lock file cannot be opened, or if the wait runs out.  The lock is released
when C<$work> returns or dies.

C<$work> must not call a sub here that saves the store.  That sub opens the
lock file again, and C<flock> makes it wait for the lock that its own process
holds, until the wait runs out.

=cut

sub locked {
    my ( $class, $file, $work ) = @_;

    my $path = "$file.lock";

    # Open for as long as the lock is held, because closing it releases the lock.
    open( my $lock, '>>', $path ) or die "Could not open $path: $!\n";    ## no critic (InputOutput::RequireBriefOpen)

    my $until = time() + $LOCK_WAIT;
    while ( !flock( $lock, LOCK_EX | LOCK_NB ) ) {
        die "Another process has been writing $file for $LOCK_WAIT seconds, and still holds $path.\n"
          if time() >= $until;
        sleep(0.1);
    }

    return $work->();
}

=head2 $group = _group_named($kdbx, $title)

The group called C<$title>, anywhere in the database, or undef.  Dies when two
groups answer to the name, naming where each one is: a reference says which
group it wants and nothing can choose between them.

C<find_group> is not used for this, nor C<find_entry> below.  Those take a
C<group> in their query, and this database is opened through
L<File::KeePass::KDBX>, whose groups carry an C<id> rather than the C<gid> that
L<File::KeePass> documents.  So the query held C<group =E<gt> undef>, which
matched on the title alone: every entry this module ever wrote went to the root
group whatever its reference said, and a title that existed twice made every
lookup of it die with two hash addresses and no name.  Walking the tree says
what was meant and cannot be read two ways.

=cut

sub _group_named {
    my ( $class, $kdbx, $title ) = @_;

    my @found = _groups_under( $kdbx->groups, $title, q{} );
    die "More than one group is called '$title': " . join( ', ', map { $_->{path} } @found ) . ".\n" . "A reference names one group, so give them different names.\n"
      if @found > 1;

    return @found ? $found[0]{group} : undef;
}

# Every group of that name in the forest, with the path that reached it.
sub _groups_under {
    my ( $groups, $title, $path ) = @_;

    my @found;
    foreach my $group ( @{ $groups // [] } ) {
        my $here = $path ? "$path/$group->{title}" : $group->{title};

        push( @found, { group => $group, path => $here } ) if defined $group->{title} && $group->{title} eq $title;
        push( @found, _groups_under( $group->{groups}, $title, $here ) );
    }

    return @found;
}

=head2 $entry = _entry_named($group, $title)

The entry called C<$title> in C<$group>, or undef.  Not in a subgroup of it: a
reference names one group, and an entry of the same name a level down is a
different entry.

Dies when the group holds two entries of that name, because nothing can choose
between them either.

=cut

sub _entry_named {
    my ( $class, $group, $title ) = @_;

    my @found = grep { defined $_->{title} && $_->{title} eq $title } @{ $group->{entries} // [] };
    die "The group '$group->{title}' holds " . scalar(@found) . " entries called '$title'.\n" . "A reference names one entry, so delete the ones that are not wanted: bin/forget_secret does that.\n"
      if @found > 1;

    return @found ? $found[0] : undef;
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

=head2 names_a_secret($field)

Whether a configuration field called C<$field> holds a secret, by its name: a
password, a secret, a token, a credential, a key, or a name that ends in
C<_pw>.  A name that ends in C<_file> or C<_path> is a location, not a secret,
as the C<key_file> of backup holds a filename such as F<backup.rsa>.

=cut

sub names_a_secret {
    my ( $class, $field ) = @_;
    return 0 if !defined $field || $field =~ m/_(?:file|path)\z/;
    return $field =~ m/pass|secret|token|credential|(?:\A|_)(?:key|pw)\z/ ? 1 : 0;
}

=head1 SEE ALSO

L<File::KeePass::KDBX>

=cut

1;
