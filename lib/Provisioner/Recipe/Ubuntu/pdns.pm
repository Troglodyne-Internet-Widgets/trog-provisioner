package Provisioner::Recipe::Ubuntu::pdns;

#ABSTRACT: What pdns needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::pdns};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- release() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::pdns - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::pdns>.

=cut

sub deps {
    return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libconfig-simple-perl libnet-dns-perl libjson-perl};
}

=head2 @sources = $recipe->apt_sources(%opts)

The release train of the authoritative server that C<repo_branch> names, from
C<repo.powerdns.com>.  It pins C<pdns-*> above Ubuntu, as PowerDNS says to, so
the server and its backend come from one release.  The recursor is not in this
archive, and comes from Ubuntu.

=cut

sub apt_sources {
    my ( $self, %opts ) = @_;

    my %args   = $self->args;
    my $branch = $opts{repo_branch} // $args{properties}{repo_branch}{default};
    return {
        name       => 'powerdns',
        uri        => 'https://repo.powerdns.com/ubuntu',
        suites     => [ 'Provisioner::Recipe::ubuntu'->release() . "-$branch" ],
        components => ['main'],
        key        => 'https://repo.powerdns.com/FD380FBB-pub.asc',
        pin        => { packages => 'pdns-*', priority => 600 },
    };
}

1;
