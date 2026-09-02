package Perl::Critic::Policy::Trog::ProhibitUseLib;

use strict;
use warnings;

use Perl::Critic::Utils qw{:severities};
use parent 'Perl::Critic::Policy';

our $VERSION = '0.01';

my $DESC = q{'use lib' hardcodes a path};
my $EXPL = q{Use FindBin::libs instead, which finds the lib dir relative to the script};

=head1 NAME

Perl::Critic::Policy::Trog::ProhibitUseLib - use FindBin::libs, not 'use lib'

=head1 DESCRIPTION

C<use lib "$FindBin::Bin/../lib"> spells out a path relative to a script that
may later move, in every single script, and gets it subtly wrong when one of
them moves a directory deeper.  L<FindBin::libs> walks up from the script and
finds the C<lib> directory itself, which is both shorter and right.

    use lib "$FindBin::Bin/../lib";     # not ok
    use lib::relative '../lib';         # not ok

    use FindBin::libs;                  # ok

=head1 CONFIGURATION

This policy is not configurable except for the standard options.

=cut

sub supported_parameters { return () }
sub default_severity     { return $SEVERITY_MEDIUM }
sub default_themes       { return qw{trog maintenance} }
sub applies_to           { return 'PPI::Statement::Include' }

sub violates {
    my ($self, $elem, undef) = @_;

    return () unless $elem->type() eq 'use';

    my $module = $elem->module();
    return () unless defined $module;
    return () unless $module eq 'lib' || $module eq 'lib::relative';

    return $self->violation($DESC, $EXPL, $elem);
}

1;
