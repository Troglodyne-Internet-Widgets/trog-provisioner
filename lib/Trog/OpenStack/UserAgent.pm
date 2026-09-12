package Trog::OpenStack::UserAgent;

#ABSTRACT: an LWP::UserAgent that checks the certificate it was given.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent 'LWP::UserAgent';

=head1 NAME

Trog::OpenStack::UserAgent - an LWP::UserAgent that checks the certificate it
was given

=head1 SYNOPSIS

    OpenStack::Client->new($endpoint, package_ua => 'Trog::OpenStack::UserAgent');

=head1 DESCRIPTION

L<OpenStack::Client>'s constructor builds its user agent with

    ssl_opts => { verify_hostname => 0 }

hardcoded, and offers no argument to say otherwise.  The one thing it does let
you choose is the class it calls C<new> on -- so this is that class, and it puts
verification back.

This is not housekeeping.  Every request after the first carries C<X-Auth-Token>,
a bearer credential good until the token expires; with hostname verification off
we hand it to whatever answered the connection, and a production cloud reached
over the internet is exactly where that matters.

=head1 CLASS METHODS

=head2 new(%opts)

As L<LWP::UserAgent>, with C<verify_hostname> and C<SSL_verify_mode> forced on
after whatever the caller asked for.

=cut

sub new {
    my ( $class, %opts ) = @_;

    # Last word rather than a default, because the caller we exist for is the
    # one passing verify_hostname => 0.
    $opts{ssl_opts} = {
        %{ $opts{ssl_opts} // {} },
        verify_hostname => 1,
        SSL_verify_mode => 1,
    };

    return $class->SUPER::new(%opts);
}

=head1 SEE ALSO

L<Trog::OpenStack::Auth>, which is what asks for this.

=cut

1;
