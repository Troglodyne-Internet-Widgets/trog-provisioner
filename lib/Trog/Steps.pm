package Trog::Steps;

#ABSTRACT: Do what the recipes of a domain need done on a machine that is not its guest, and undo it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util();
use Net::IP();
use Provisioner::Cookbook();
use Trog::HV();
use Trog::Hypervisors();

=head1 NAME

Trog::Steps - do what the recipes of a domain need done on a machine that is
not its guest, and undo it

=head1 SYNOPSIS

    # bin/provision, after the secrets are on the guest
    Trog::Steps->apply( $domain, when => 'secrets', secrets => \%by_ref );

    # bin/provision, after the makefile of the guest finished
    Trog::Steps->apply( $domain, when => 'built', address => $ip );

    # bin/destroy
    Trog::Steps->revert( $domain, dryrun => $dryrun );

=head1 DESCRIPTION

A recipe says what it needs done outside its guest in C<outside_steps>.  See
L<Provisioner::Recipe/@steps = $recipe-E<gt>outside_steps($domain, %opts)> for
what a step is.  This module finds the machine that each step names, asks the
step for its actions, and runs each action that is not done yet.

The recipe layer cannot load L<Trog::HV>, so a step names its machine, and this
module, which is in the machine layer, builds it.  That is why the actions come
from a code reference that takes the machine: only here is there a machine to
give it.

=head2 The machine that a step names

=over 4

=item C<'hypervisor'>

The hypervisor of this run, as L<Trog::HV/new> returns it.

=item C<< { hypervisor => NAME } >>

The block C<NAME> of F<hypervisors.conf>, as the account that the block names.
That is the account of the operator, with sudo for everything.

=item C<< { uri => URI } >>

The machine of a libvirt URI, as the user in the URI.

=back

=cut

# The machine of $spec in words, for a message that cannot build it.
my sub describe_spec ($spec) {
    return "the hypervisor $spec->{hypervisor}" if ref $spec eq 'HASH' && defined $spec->{hypervisor};
    return $spec->{uri}                         if ref $spec eq 'HASH' && defined $spec->{uri};
    return 'the hypervisor of this run'         if ( $spec // q{} ) eq 'hypervisor';
    return 'a machine with no name';
}

# The machine that $spec names.  See "The machine that a step names".
my sub machine_of ( $spec, $hvconf ) {
    return Trog::HV->new() if !ref $spec && ( $spec // q{} ) eq 'hypervisor';
    die 'A step names a machine this module does not know: ' . describe_spec($spec) . "\n" unless ref $spec eq 'HASH';

    return Trog::HV->candidate( uri => $spec->{uri} ) if defined $spec->{uri};

    if ( defined $spec->{hypervisor} ) {
        my $fleet = Trog::Hypervisors->load( $hvconf // Trog::Hypervisors->default_path );
        die "A step works on the hypervisor $spec->{hypervisor} as the account of " . $fleet->{path} . ", and there is no such file\n"
          unless $fleet->configured;
        return $fleet->hypervisor( $spec->{hypervisor} );
    }
    die 'A step names a machine this module does not know: ' . describe_spec($spec) . "\n";
}

# What every step gets besides its machine.  The directory is the one of the
# domain on this machine, where a step can leave what its revert needs.
my sub context ( $domain, %opts ) {
    return (
        domain     => $domain,
        domain_dir => Trog::HV->new()->domain_dir . "/$domain",
        dryrun     => $opts{dryrun} ? 1 : 0,
        secrets    => $opts{secrets} // {},
        ( defined $opts{address} ? ( address => $opts{address} ) : () ),
    );
}

=head1 CLASS METHODS

=head2 @steps = Trog::Steps->of($domain)

The steps of every recipe of C<$domain>, in the order of the recipe names, from
the configuration of C<$domain> as written.  After the steps of a recipe that
C<sends_mail> comes C<reverse_dns_step>, which no recipe can leave out, since
it is not one of its C<outside_steps>.  Two steps with one C<id> are one step,
the first, so a guest with two recipes that send mail gets one.  A recipe that
dies on the configuration dies here.

=cut

sub of {
    my ( $class, $domain ) = @_;

    my $config = eval { Provisioner::Cookbook->domain_config($domain) } // {};

    my ( %seen, @steps );
    foreach my $name ( sort grep { Provisioner::Cookbook->has($_) } keys %$config ) {
        my %opts   = ref $config->{$name} eq 'HASH' ? %{ $config->{$name} } : ();
        my $recipe = Provisioner::Cookbook->load($name);
        my @own    = ( $recipe->outside_steps( $domain, %opts ), $recipe->sends_mail ? $class->reverse_dns_step($domain) : () );
        push @steps, grep { !defined $_->{id} || !$seen{ $_->{id} }++ } @own;
    }
    return @steps;
}

=head2 $step = Trog::Steps->reverse_dns_step($domain)

The step that sets the reverse DNS of the guest of C<$domain>, after its build,
to C<helo_name_of> the domain in L<Provisioner::Cookbook>, through the
C<set_reverse_dns> of the hypervisor of the run.  The guest is C<machine_of>
the domain, so a tenant sets the reverse DNS of the guest of its host.  Its
C<id> is C<reverse_dns>, and it has no revert.

A refusal of the hypervisor is a warning, because the guest works, and only its
mail out suffers.  When the hypervisor offers no way and the address of the
guest is public, the step says what the operator must set, and where.  A
private address gets neither, because no receiver of mail connects from it.

=cut

sub reverse_dns_step {
    my ( $class, $domain ) = @_;

    return {
        id      => 'reverse_dns',
        machine => 'hypervisor',
        when    => 'built',
        apply   => sub ( $hv, %context ) {
            my $machine = Provisioner::Cookbook->machine_of($domain);
            my $name    = Provisioner::Cookbook->helo_name_of($domain);
            return {
                what => "point the reverse DNS of $machine at $name",
                done => sub { 0 },
                do   => sub {
                    my $set = eval { $hv->set_reverse_dns( $machine, $name ) };
                    if ( my $error = $@ ) {
                        warn "Could not set the reverse DNS of $domain to $name, so receivers can reject its mail.\n$error";
                        return;
                    }
                    if ($set) {
                        print "The reverse DNS of $set is now $name\n";
                        return;
                    }

                    my $ip = defined $context{address} ? Net::IP->new( $context{address} ) : undef;
                    print "Set the reverse DNS of $context{address} to $name where the address is held.  " . $hv->describe . " offers no way to do it from here, and until it is set, receivers can reject the mail of $domain.\n"
                      if $ip && $ip->iptype eq 'PUBLIC';
                    return;
                },
            };
        },
    };
}

=head2 $count = Trog::Steps->apply($domain, %opts)

Runs the C<apply> of each step of C<$domain> whose C<when> is C<$opts{when}>,
and returns how many actions ran.  A step without an C<apply> only takes back
what an earlier configuration made, and this skips it.  C<%opts> takes C<when>, which is required,
C<dryrun>, C<hvconf>, and what goes into the context of a step: C<secrets> and
C<address>.  A dry run asks each machine what is done, says what would run, and
runs nothing.  It has no secrets, because a dry run does not open the store.

Dies when an action dies, because a step that C<bin/provision> needs and could
not do is a build that does not work.  A step that can fail without harm warns
in its own C<do>.

=cut

# The moments of a provision, in their order.
my @WHEN = qw{secrets built};
my %WHEN = map { $_ => 1 } @WHEN;

sub apply {
    my ( $class, $domain, %opts ) = @_;
    die "Trog::Steps->apply needs a when that is one of: " . join( ', ', @WHEN ) . "\n" unless $WHEN{ $opts{when} // q{} };

    my %context = context( $domain, %opts );
    my $count   = 0;
    foreach my $step ( grep { $_->{apply} && $_->{when} eq $opts{when} } $class->of($domain) ) {
        my $machine = machine_of( $step->{machine}, $opts{hvconf} );
        $count += run( [ $step->{apply}->( $machine, %context ) ], $opts{dryrun} );
    }
    return $count;
}

=head2 $count = Trog::Steps->preview($domain, %opts)

A dry run of every moment of C<$domain>, in the order of a provision, for a
dry run of F<bin/provision>, which stops before the first of them.  Prints a
line that names the domain, and then what C<apply> says with C<dryrun>.
Prints nothing for a domain with no step to apply.  C<%opts> takes C<hvconf>.
Returns how many actions would run.

=cut

sub preview {
    my ( $class, $domain, %opts ) = @_;
    return 0 unless List::Util::any { $_->{apply} } $class->of($domain);

    print "What $domain needs on other machines:\n";
    return List::Util::sum0( map { $class->apply( $domain, %opts, when => $_, dryrun => 1 ) } @WHEN );
}

=head2 $count = Trog::Steps->revert($domain, %opts)

Runs the C<revert> of each step of C<$domain> that has one, last step first, and
returns how many actions ran.  C<%opts> takes C<dryrun> and C<hvconf>.  The
context has no secrets, so that a teardown never asks for the password of the
store.

A step that dies gets a warning, and the next step still runs, because the
guest is going away either way.  The warning names the machine, and the step
says in its message what stays there.

=cut

sub revert {
    my ( $class, $domain, %opts ) = @_;

    my %context = context( $domain, %opts );
    my $count   = 0;
    foreach my $step ( reverse grep { $_->{revert} } $class->of($domain) ) {
        my $where = describe_spec( $step->{machine} );
        eval {
            my $machine = machine_of( $step->{machine}, $opts{hvconf} );
            $count += run( [ $step->{revert}->( $machine, %context ) ], $opts{dryrun} );
            1;
        } or warn "Could not undo a step of $domain on $where: $@";
    }
    return $count;
}

=head2 $count = Trog::Steps::run(\@actions, $dryrun)

Runs each action whose C<done> returns false, and prints what it does.  An
action is a hash reference of C<what>, a sentence that starts with a verb, and
C<done> and C<do>, two code references.  With C<$dryrun>, prints what would
run and runs nothing.  A C<do> that dies stops the run.  Returns how many
actions ran or would run.

=cut

sub run {
    my ( $actions, $dryrun ) = @_;

    my $count = 0;
    foreach my $action (@$actions) {
        if ( $action->{done}->() ) {
            print "  ok    $action->{what}\n";
            next;
        }
        $count++;
        print $dryrun ? "  would $action->{what}\n" : "  now   $action->{what}\n";
        $action->{do}->() unless $dryrun;
    }
    return $count;
}

1;
