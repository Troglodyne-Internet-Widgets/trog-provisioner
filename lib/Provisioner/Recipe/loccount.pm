package Provisioner::Recipe::loccount;

#ABSTRACT: Build and install loccount, which counts lines of code and estimates their cost.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

my $RELEASE = qr/\A \d+ [.] \d+ (?: [.] \d+ )? \z/;

=head1 Provisioner::Recipe::loccount

=head2 SYNOPSIS

    somedomain:
        loccount:

    # Or naming the tag:
    somedomain:
        loccount:
            version: "2.28"

=head2 DESCRIPTION

loccount, by Eric S. Raymond, L<https://gitlab.com/esr/loccount>, counts the
source lines of each language in a tree, and makes COCOMO estimates of the
cost to write it.  No distribution packages it, so F<scripts/build_loccount.sh>
clones the tag C<version> and builds it with the Go of
L<Provisioner::Recipe::go>, into F</usr/local/bin/loccount>.  It builds only
when F</usr/local/bin/loccount> reports another version.

The build is in the global half, because a program is a fact about the
machine rather than about a domain.  The fragment queues it as a postrun
task, because make runs the targets in parallel, and nothing orders the go
target before this one.  The postrun runs after every target.

The build runs C<go generate>, which runs F<tablegen.py>.  That script reads
F<languages.yaml> with ruamel.yaml when it can, and with PyYAML when it
cannot.  PyYAML refuses F<languages.yaml> of 2.28, so ruamel.yaml is a
dependency of the build.  A C<?> in a flow collection stops PyYAML, which is
L<https://gitlab.com/esr/loccount/-/work_items/33>.  When a release fixes
that, the dependency can go.

=head1 METHODS

=head2 deps

L<Provisioner::Recipe::Ubuntu::loccount> lists the packages.

=head2 args()

The schema of the options: C<version>, the tag of loccount to build, such as
C<2.28>, which is also the default.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            version => {
                type        => 'string',
                pattern     => "$RELEASE",
                default     => '2.28',
                description => 'The tag of loccount to build, which is its version, such as 2.28.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<go>, which builds it, with no options.

Returns the pair of C<go> and a sub that returns an empty list.

    my %required = $recipe->required_recipes( domain => 'test.test' );

=cut

sub required_recipes {
    return ( go => sub { return () } );
}

=head2 tests()

Returns a list of the test templates that run on the guest:
F<loccount.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{loccount.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

C<gitlab.com>, which the clone names, and C<proxy.golang.org>, which C<go
build> fetches the modules of F<go.mod> from.  No template here names the
proxy: go knows it, and this is the only thing that says so.

Returns those two host names, as a list.

    my @hosts = $recipe->fetch_hosts();

=cut

sub fetch_hosts {
    return qw{gitlab.com proxy.golang.org};
}

1;
