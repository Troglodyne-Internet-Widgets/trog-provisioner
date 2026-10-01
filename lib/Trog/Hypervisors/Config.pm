package Trog::Hypervisors::Config;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use Config::Simple();
use File::Slurper();
use List::Util qw{uniq};
use Trog::Config();
use Trog::Secrets();

=head1 NAME

Trog::Hypervisors::Config - what F<hypervisors.conf> says, and nothing about
what to do with it

=head1 SYNOPSIS

    use Trog::Hypervisors::Config();

    my $fleet = Trog::Hypervisors::Config->load( Trog::Hypervisors::Config->default_path );
    my @refs  = $fleet->secret_references;

=head1 DESCRIPTION

Reads the fleet's file into its blocks, in the order of the file.
L<Trog::Hypervisors> is a subclass that builds hypervisors out of those blocks
and chooses between them.  This one builds nothing, so a module that only needs
to know what the file says -- L<Provisioner::Cookbook>, counting the secrets an
installation wants -- can load it without loading every backend, and without
the cycle that loading L<Trog::Hypervisors> from there would make.

=head1 CLASS METHODS

=head2 load($path)

Reads a fleet from F<hypervisors.conf> and returns it.  No fleet is a normal
state.  So when C<$path> is undef, does not exist or cannot be read, this
returns an empty fleet, which means that no fleet is configured.

Dies when a file it can read names no hypervisor.  That includes a file with
keys but no C<[name]> header.

=cut

sub load {
    my ( $class, $path ) = @_;

    my $self = bless { path => $path, order => [], blocks => {} }, $class;
    return $self unless defined $path;

    my $config = eval { Config::Simple->new($path) } or return $self;

    # Config::Simple returns "block.key" pairs in a hash and cannot list the
    # block names, so the order must come from the file itself.
    my %vars = $config->vars();
    my %in_file;
    foreach my $key ( keys %vars ) {
        my ($block) = $key =~ m/\A([^.]+)\./ or next;
        $in_file{$block} = 1;
    }

    # The [block] headers, in file order.  Config::Simple puts any key outside a
    # header under default, which has no header line, so the names that this
    # does not find follow them.
    my $text  = eval { File::Slurper::read_text($path) } // q{};
    my @order = map { m/\A\s*\[([^\]]+)\]/ ? $1 : () } split m/\n/, $text;

    my %seen;
    foreach my $block ( @order, sort keys %in_file ) {
        next unless $in_file{$block};
        next if $seen{$block}++;
        push @{ $self->{order} }, $block;
        $self->{blocks}{$block} = $config->get_block($block);
    }

    # Config::Simple puts any key outside a [block] under 'default', so a file
    # with no headers looks like one hypervisor with that name.
    die "$path names no hypervisors; every one needs a [name] header of its own\n"
      if !@{ $self->{order} } || ( @{ $self->{order} } == 1 && $self->{order}[0] eq 'default' );

    return $self;
}

=head2 default_path

Returns the path of F<hypervisors.conf> when the caller names no other.  It is
in the configuration directory, with the rest of the configuration of this
installation.  See L<Trog::Config>.

=cut

sub default_path { return Trog::Config->path('hypervisors.conf') }

=head1 METHODS

=head2 configured

Returns true when there is a fleet.  When it is false, the other methods here
have nothing to say, and the hypervisor comes from F<provision.conf>.

=head2 names

Returns the hypervisor names, in the order of the file.

=cut

sub configured ($self) { return scalar @{ $self->{order} } ? 1 : 0 }
sub names      ($self) { return @{ $self->{order} } }

=head2 secret_references

Returns every C<secret:> reference that a block of the fleet names, sorted and
without duplicates.  A hypervisor's credential is one, such as the token of a
Linode or SolusVM block.  Empty when there is no fleet.

=cut

sub secret_references ($self) {
    my %needed = Trog::Secrets->needed( $self->{blocks} );
    return uniq( sort values %needed );
}

=head1 SEE ALSO

L<Trog::Hypervisors>

=cut

1;
