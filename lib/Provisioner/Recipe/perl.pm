package Provisioner::Recipe::perl;

#ABSTRACT: Build and install the latest perl into /opt/perl5.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perl

=head2 SYNOPSIS

    somedomain:
        perl:

=head2 DESCRIPTION

Downloads the latest perl, compiles it and slams it into /opt/perl5/$version

Sets up a .bashrc in the install_dir which includes that perl's bindir in $PATH.

TODO: allow specification of version.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{perlbrew libcarp-always-perl};
    }
    die "Unsupported packager";
}

sub enrich {
    my ($self, %opts) = @_;

    # Whose perl this is.  Required, and nothing that pulls this recipe in
    # supplies it -- tpsgi requires it with an empty configuration -- so a
    # domain that never set a service user could not build at all.  The admin
    # user is who owns everything else in that case, and is what nvm does with
    # the same field.
    $opts{user} //= $opts{admin_user};

    return %opts;
}

sub args {
    return (
        type       => 'object',
        # user is not required, because enrich fills it in from admin_user and
        # enrich runs after validation -- a required field cannot be satisfied
        # by one.  It is always set by the time a template sees it.
        properties => {
            user => { type => 'string' },
        },
    );
}

sub template_files {
    return (
        'perl.critic.rc.tt' => 'perl.critic.rc',
        'perl.tidy.rc.tt'   => 'perl.tidy.rc',
    );
}

sub tests {
    return qw{perl.tt};
}

1;
