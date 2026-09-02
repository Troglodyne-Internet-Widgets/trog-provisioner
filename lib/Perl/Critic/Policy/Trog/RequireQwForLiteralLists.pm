package Perl::Critic::Policy::Trog::RequireQwForLiteralLists;

use strict;
use warnings;

use Perl::Critic::Utils qw{:severities};
use parent 'Perl::Critic::Policy';

our $VERSION = '0.01';

my $DESC = q{Run of quoted literals should be a qw() list};
my $EXPL = q{Write qw{a b c} instead of 'a', 'b', 'c'};

=head1 NAME

Perl::Critic::Policy::Trog::RequireQwForLiteralLists - qw{} beats a row of quotes

=head1 DESCRIPTION

A run of plain quoted words handed to something that takes a list is a C<qw()>
list written the long way.  The quotes and commas carry no information, they
just give you more places to typo, and they hide the fact that the whole run is
one command line:

    $hv->system_hv('sudo', 'rm', '-f', $conf);     # not ok
    return ('virsh', '-c', $uri, @args);           # not ok

    $hv->system_hv(qw{sudo rm -f}, $conf);         # ok
    return ('virsh', @args);                       # ok, too short to matter

Only runs of plain words are reported: anything with whitespace, a sigil, a
backslash, or a C<< => >> in it stays as it is, since C<qw> would change what it
means.

=head1 CONFIGURATION

=over 4

=item C<min_run_length>

How many literals in a row before it's worth complaining about.  Defaults to 3.

=back

=cut

sub supported_parameters {
    return ({
        name           => 'min_run_length',
        description    => 'How many adjacent literals before this is a qw() list.',
        default_string => '3',
        behavior       => 'integer',
        integer_minimum => 2,
    });
}

sub default_severity { return $SEVERITY_LOW }
sub default_themes   { return qw{trog cosmetic} }
sub applies_to       { return qw{PPI::Token::Quote::Single PPI::Token::Quote::Double PPI::Token::Quote::Literal} }

# A literal that qw{} could hold without changing its meaning: a bare word with
# no whitespace, no interpolation, and no escapes.
sub _is_qw_able {
    my ($elem) = @_;
    return 0 unless $elem && $elem->isa('PPI::Token::Quote');

    my $string = $elem->string();
    return 0 unless defined $string && length $string;
    return 0 if $string =~ m/[\s\\'"]/;
    return 0 if $elem->isa('PPI::Token::Quote::Double') && $string =~ m/[\$\@]/;
    return 1;
}

sub _is_plain_comma {
    my ($elem) = @_;
    return $elem && $elem->isa('PPI::Token::Operator') && $elem->content() eq ',';
}

sub violates {
    my ($self, $elem, undef) = @_;

    return () unless _is_qw_able($elem);

    # Only report from the head of a run, or we'd fire once per element.
    my $comma = $elem->sprevious_sibling();
    return () if _is_plain_comma($comma) && _is_qw_able($comma->sprevious_sibling());

    my $length = 1;
    my $cursor = $elem;
    while (1) {
        my $next = $cursor->snext_sibling();
        last unless _is_plain_comma($next);
        my $after = $next->snext_sibling();
        last unless _is_qw_able($after);
        $length++;
        $cursor = $after;
    }

    return () if $length < $self->{_min_run_length};
    return $self->violation($DESC, $EXPL, $elem);
}

1;
