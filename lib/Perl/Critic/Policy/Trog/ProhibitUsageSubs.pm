package Perl::Critic::Policy::Trog::ProhibitUsageSubs;

use strict;
use warnings;

use Perl::Critic::Utils qw{:severities};
use parent 'Perl::Critic::Policy';

our $VERSION = '0.01';

my $DESC = q{usage() duplicates documentation that belongs in POD};
my $EXPL = q{Document the interface in POD and print it with Pod::Usage::pod2usage()};

=head1 NAME

Perl::Critic::Policy::Trog::ProhibitUsageSubs - document the interface once, in POD

=head1 DESCRIPTION

A hand-rolled C<usage()> is a second copy of the script's interface, kept in
sync with the POD and with C<GetOptions> by hope alone.  Whichever copy the
reader finds first is the one they will believe, and it is usually the stale
one.

Write the synopsis and options in POD, where C<perldoc> and the man page will
find them too, and let L<Pod::Usage> print it:

    sub usage {                                  # not ok
        return "Usage: $0 [--name NAME] DOMAIN\n";
    }
    die usage() unless $domain;

    pod2usage(-exitval => 2, -verbose => 1,      # ok
        -input => __FILE__, -message => 'No domain passed') unless $domain;

=head1 CONFIGURATION

=over 4

=item C<sub_names>

Space separated list of subroutine names to complain about.  Defaults to
C<usage _usage print_usage usage_message>.

=back

=cut

sub supported_parameters {
    return ({
        name            => 'sub_names',
        description     => 'Subroutine names that should be POD instead.',
        default_string  => 'usage _usage print_usage usage_message',
        behavior        => 'string list',
    });
}

sub default_severity { return $SEVERITY_MEDIUM }
sub default_themes   { return qw{trog maintenance} }
sub applies_to       { return 'PPI::Statement::Sub' }

sub violates {
    my ($self, $elem, undef) = @_;

    my $name = $elem->name();
    return () unless defined $name;

    # Fully qualified names count too; it's the last segment that matters.
    $name =~ s/\A.*:://;
    return () unless $self->{_sub_names}{$name};

    return $self->violation($DESC, $EXPL, $elem);
}

1;
