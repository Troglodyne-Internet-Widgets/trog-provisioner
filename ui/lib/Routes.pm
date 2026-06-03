package Routes;

# tPSGI route definitions for the provisioner web UI.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";

use Config::Simple ();
use Trog::Provisioner::Web ();

my $conf_file = "$FindBin::Bin/../ui.conf";
my $_conf;

sub _conf {
    return $_conf if $_conf;
    $_conf = Config::Simple->new($conf_file) or die "Cannot read $conf_file";
    return $_conf;
}

sub _provisioners_repo { _conf()->param('provisioners_repo') || '/opt/projects/provisioners' }
sub _domain_dir        { _conf()->param('domain_dir')        || '/opt/domains' }

our @routes = (
    '/' => {
        method    => 'GET',
        callbacks => { '*' => \&index },
    },
    '/provision' => {
        method    => 'POST',
        callbacks => { '*' => \&provision },
    },
);

sub index {
    my ( $self, $query ) = @_;

    my @recipes;
    local $@;
    eval { @recipes = Trog::Provisioner::Web::get_recipes( _provisioners_repo() ) };
    if ($@) {
        return $self->error( $query, "Could not load recipes: $@" );
    }

    my $body = Trog::Provisioner::Web::index_html( \@recipes );
    return [
        200,
        [ 'Content-Type' => 'text/html; charset=UTF-8', 'Content-Length' => length($body) ],
        [$body],
    ];
}

sub provision {
    my ( $self, $query ) = @_;

    my $domain = $query->{domain};
    unless ( $domain && $domain =~ m/\A[\w.\-]+\z/ ) {
        return $self->badrequest( $query, 'Invalid or missing domain parameter' );
    }

    my $provisioners_repo = _provisioners_repo();
    my $domain_dir        = _domain_dir();

    return $self->stream_raw_http(
        $query, 0,
        sub {
            print "Content-Type: text/plain; charset=UTF-8\n";
            print "Transfer-Encoding: chunked\n\n";
            Trog::Provisioner::Web::stream_provision(
                $domain, $provisioners_repo, $domain_dir, \*STDOUT
            );
        },
        undef,
        sub {
            # error handler
            print "ERROR: provisioning failed\n";
        }
    );
}

1;
