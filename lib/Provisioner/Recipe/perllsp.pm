package Provisioner::Recipe::perllsp;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perllsp

=head2 SYNOPSIS

    somedomain:
        perllsp:

    # Or with explicit perl path (useful when the perl recipe is not active):
    somedomain:
        perllsp:
            perl_path: /opt/perl5/perl-5.38.0/bin/perl

=head2 DESCRIPTION

Installs L<PerlNavigator|https://github.com/bscan/PerlNavigator>, a
Language Server Protocol (LSP) implementation for Perl, and configures
vim to use it via the C<vim-lsp> plugin family.

When the C<perl> recipe is co-listed in the same domain the template
detects C</opt/perl5/*/bin/perl> and passes the found path to
PerlNavigator so it analyses code with the custom perl build rather
than the system default.

Vim plugins are installed into C<~admin_user/.vim/pack/> using vim 8+
native package loading — no plugin manager required.

=head3 deps

System packages: C<nodejs>, C<npm>, C<vim>, C<git>.

=head3 validate

No required fields.  Optional:

=over 4

=item perl_path

Absolute path to the perl binary PerlNavigator should use.  Defaults to
the system perl (C</usr/bin/perl>); overridden at runtime by the template
when the C<perl> module is present.

=back

=head3 template_files

Renders C<perllsp.vimrc.tt> into a C<perllsp.vim> vimrc snippet placed in
the admin user's C<~/.vim/> directory.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{nodejs npm vim git};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;
    $opts{perl_path} //= '/usr/bin/perl';
    return %opts;
}

sub template_files {
    return (
        'perllsp.vimrc.tt' => 'perllsp.vim',
    );
}

sub tests {
    return qw{perllsp.tt};
}

1;
