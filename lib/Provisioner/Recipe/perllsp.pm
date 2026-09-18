package Provisioner::Recipe::perllsp;

#ABSTRACT: Install PerlNavigator and configure vim to use it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perllsp

=head2 SYNOPSIS

    somedomain:
        perllsp:

    # Or name the perl to use, for example when the perl recipe is not active:
    somedomain:
        perllsp:
            perl_path: /opt/perl5/perl-5.38.0/bin/perl

=head2 DESCRIPTION

Installs L<PerlNavigator|https://github.com/bscan/PerlNavigator>, a Language
Server Protocol (LSP) implementation for Perl.  It also configures vim to use
PerlNavigator through the C<vim-lsp> plugin family.

If a perl exists under C</opt/perl5/*/bin/perl>, the vim configuration gives
that path to PerlNavigator.  The C<perl> recipe puts its build there.
PerlNavigator then analyzes code with that perl and not with the system perl.

The vim plugins go into C<~admin_user/.vim/pack/>.  Vim 8 and later loads
packages from there, so no plugin manager is necessary.  Each plugin is pinned
to a commit, and the recipe fetches the tarball of that commit.  Nothing here
uses the history of a plugin.  The pin makes two guests built a month apart
the same guest.

=head3 deps

System packages: C<nodejs>, C<npm>, C<vim>.

=head3 args

No field is required.  The optional fields are:

=over 4

=item perl_path

The absolute path to the perl binary that PerlNavigator uses.  The default is
the system perl (C</usr/bin/perl>).  A perl under C</opt/perl5/> replaces it
when the vim configuration loads.

=item vim_plugins

The plugins, keyed by the directory that each one unpacks into under
C<~/.vim/pack/lsp/start/>.  Each plugin is a GitHub C<repo> and the 40-character
commit C<ref> to install.  The vim-lsp family is there by default, one entry at
a time.  So a new name adds a plugin, and the name of a default moves its pin.

    perllsp:
        vim_plugins:
            vim-lsp: { repo: prabirshrestha/vim-lsp, ref: <commit> }

=back

=head3 template_files

Renders C<perllsp.vimrc.tt> into C<perllsp.vim>, a vimrc snippet.  The fragment
installs it in the C<~/.vim/> directory of the admin user.

=cut

my %PLUGIN = (
    type       => 'object',
    required   => [qw{repo ref}],
    properties => {
        repo => { type => 'string', pattern => '\A[\w.-]+/[\w.-]+\z' },
        ref  => { type => 'string', pattern => '\A[0-9a-f]{40}\z' },
    },
);

# The vim-lsp family, each at the commit it was last checked at.  The POD says
# why a pin is a commit.
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

Turns C<vim_plugins> into C<plugins>, a list sorted by directory.  Each item has
a C<dir>, a C<repo> and a C<ref>.  Dies if a directory name is not one plain
path component, because the fragment empties that directory before it unpacks.

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

=head2 @classes = $recipe->cache_classes()

A tarball that codeload serves for a full commit SHA never changes.

=cut

sub cache_classes {
    return ( { class => 'immutable', pattern => 'codeload\.github\.com/[^/]+/[^/]+/[^/]+/[0-9a-f]{40}$' } );
}

1;
