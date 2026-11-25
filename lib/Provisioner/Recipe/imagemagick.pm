package Provisioner::Recipe::imagemagick;

#ABSTRACT: Build and install ImageMagick with perl bindings from source.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::imagemagick

=head2 SYNOPSIS

    somedomain:
        imagemagick:
            version: 7.1.0-48

=head2 DESCRIPTION

Builds ImageMagick from source with its Perl bindings, and installs it.

=head1 METHODS

=head2 $recipe->required_recipes()

Returns C<perl>.  The bindings build against the perl that the perl recipe
installs under F</opt/perl5>.  The name is paired with a code reference that
returns no options.

    my %required = $recipe->required_recipes();

=cut

sub required_recipes {
    return ( perl => sub { () } );
}

# A release of ImageMagick, such as 7.1.1-38.
my $RELEASE = qr/\A [[:digit:]]+ [.] [[:digit:]]+ [.] [[:digit:]]+ - [[:digit:]]+ \z/;

=head2 args()

The schema of the options: C<version>, required, a full release with its patch
number, such as C<7.1.1-38>.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{version}],
        properties => {

            # TODO default to the latest imagemagick version available on github releases
            # A full release with the patch number, because the archive names
            # its tarballs that way: "7.1.0" is a 404.
            version => { type => 'string', pattern => "$RELEASE" },
        },
    );
}

=head2 tests()

Returns a list of the test templates that run on the guest: F<imagemagick.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{imagemagick.tt};
}

=head2 $recipe->fetch_hosts()

C<download.imagemagick.org>, where F<scripts/build_imagick.sh> fetches the
source release.

Returns that one host name, as a list.

    my @hosts = $recipe->fetch_hosts();

=cut

sub fetch_hosts {
    return ('download.imagemagick.org');
}

=head2 $recipe->cache_classes()

A release tarball named by version.  The archive keeps it until it prunes it.
After that, the copy in the cache is the only copy left.

Returns one hash reference, with the C<class> C<immutable> and the C<pattern>
of the path of the releases, as a list.

    my @classes = $recipe->cache_classes();

=cut

sub cache_classes {
    return ( { class => 'immutable', pattern => 'download\\.imagemagick\\.org/archive/releases/' } );    ## no critic (RegularExpressions::ProhibitRegexInStrings) -- a pattern for nginx, which fetchcache.nginx.conf.tt writes into its configuration; a qr// would write (?^aa:...) there
}

1;
