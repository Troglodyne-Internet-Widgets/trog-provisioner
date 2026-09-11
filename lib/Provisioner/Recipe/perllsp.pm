package Provisioner::Recipe::perllsp;

#ABSTRACT: Install PerlNavigator and configure vim to use it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
native package loading -- no plugin manager required.  Each is pinned to a
commit and fetched as that commit's tarball: nothing here uses a plugin's
history, and a pinned commit makes two guests built a month apart the same
guest.

=head3 deps

System packages: C<nodejs>, C<npm>, C<vim>.

=head3 validate

No required fields.  Optional:

=over 4

=item perl_path

Absolute path to the perl binary PerlNavigator should use.  Defaults to
the system perl (C</usr/bin/perl>); overridden at runtime by the template
when the C<perl> module is present.

=item vim_plugins

The plugins, keyed by the directory each is unpacked into under
C<~/.vim/pack/lsp/start/>, each a GitHub C<repo> and the 40-character commit
C<ref> to install.  The vim-lsp family is there by default, one entry at a time,
so naming another plugin adds it and naming one of the defaults moves its pin.

    perllsp:
        vim_plugins:
            vim-lsp: { repo: prabirshrestha/vim-lsp, ref: <commit> }

=back

=head3 template_files

Renders C<perllsp.vimrc.tt> into a C<perllsp.vim> vimrc snippet placed in
the admin user's C<~/.vim/> directory.

=cut

my %PLUGIN = (
    type       => 'object',
    required   => [qw{repo ref}],
    properties => {
        repo => { type => 'string', pattern => '\A[\w.-]+/[\w.-]+\z' },
        ref  => { type => 'string', pattern => '\A[0-9a-f]{40}\z' },
    },
);

# The vim-lsp family, each at the commit it was last checked at.  A commit
# rather than a branch: a pin is what makes two guests built a month apart the
# same guest.
my %DEFAULT_PLUGINS = (
    'async'                => { repo => 'prabirshrestha/async.vim',            ref => '2082d13bb195f3203d41a308b89417426a7deca1' },
    'vim-lsp'              => { repo => 'prabirshrestha/vim-lsp',              ref => 'bbffa60cb08a6a2d67e2086a89699ab00a084fe9' },
    'asyncomplete.vim'     => { repo => 'prabirshrestha/asyncomplete.vim',     ref => '17b654a87a834d4e835fb7467e562b4421ad9310' },
    'asyncomplete-lsp.vim' => { repo => 'prabirshrestha/asyncomplete-lsp.vim', ref => '7cf65e7661a6047f02bd1848ad30581d040896e5' },
);

sub args {
    return (
        properties => {
            perl_path   => { type => 'string', default => '/usr/bin/perl' },
            vim_plugins => {
                type                 => 'object',
                default              => {},
                properties           => { map { $_ => { %PLUGIN, default => $DEFAULT_PLUGINS{$_} } } keys %DEFAULT_PLUGINS },
                additionalProperties => \%PLUGIN,
                description          => 'Vim plugins, keyed by the directory each is unpacked into, each a GitHub repo and the 40-character commit to install.  The vim-lsp family is there by default; naming another adds it, and naming a default moves its pin.',
            },
        },
    );
}

=head3 enrich

Turns C<vim_plugins> into C<plugins>, a list in directory order, each with the
C<dir>, C<repo> and C<ref>.  Dies on a directory name that is not one plain path
component, since the fragment empties that directory before unpacking into it.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @bad = grep { !m/\A\w[\w.-]*\z/ } keys %{ $opts{vim_plugins} };
    die "perllsp vim_plugins must be keyed by a plain directory name; these are not: @bad\n" if @bad;

    $opts{plugins} = [ map { { dir => $_, %{ $opts{vim_plugins}{$_} } } } sort keys %{ $opts{vim_plugins} } ];

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

=head2 @hosts = $recipe->fetch_hosts()

C<codeload.github.com>, which serves the pinned tarballs of the vim plugins.

=cut

sub fetch_hosts {
    return ('codeload.github.com');
}

1;
