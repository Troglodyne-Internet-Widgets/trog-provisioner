package Trog::OpenStack::UserAgent;

#ABSTRACT: an LWP::UserAgent that checks the certificate it was given.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent 'LWP::UserAgent';

=head1 NAME

Trog::OpenStack::UserAgent - an LWP::UserAgent that checks the certificate it
was given

=head1 SYNOPSIS

    OpenStack::Client->new($endpoint, package_ua => 'Trog::OpenStack::UserAgent');

=head1 DESCRIPTION

The constructor of L<OpenStack::Client> makes its user agent with

    ssl_opts => { verify_hostname => 0 }

in its code, and no argument changes it.  But you can choose the class that it
calls C<new> on.  This is that class, and it turns the check back on.

Each request after the first carries C<X-Auth-Token>.  This is a bearer
credential, good until the token expires.  Without the hostname check, the
token goes to any server that answers the connection.  A production cloud over
the internet is where that is most dangerous.

=head1 CLASS METHODS

=head2 new(%opts)

Returns a new user agent, as L<LWP::UserAgent> does.  C<verify_hostname> and
C<SSL_verify_mode> are always on, whatever C<%opts> asks for.

=cut

sub new {
    my ( $class, %opts ) = @_;

    # These come last, not as defaults, because OpenStack::Client passes
    # verify_hostname => 0.
    $opts{ssl_opts} = {
        %{ $opts{ssl_opts} // {} },
        verify_hostname => 1,
        SSL_verify_mode => 1,
    };

    return $class->SUPER::new(%opts);
}

=head1 SEE ALSO

L<Trog::OpenStack::Auth>, which uses this class.

=cut

1;
