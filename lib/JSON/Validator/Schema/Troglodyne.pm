package JSON::Validator::Schema::Troglodyne;

use 5.041;

use strict;
use warnings;

use parent qw{JSON::Validator::Schema::OpenAPIv3};

use Data::Validate::Email();

=head1 JSON::Validator::Schema::Troglodyne

Troglodyne LLC's extensions to L<JSON::Validator::Schema::OpenAPIv3>.

Since there isn't a mechanism to inject validators into L<JSON::Validator::Formats>, here we are.

=head2 TYPES

=head3 email

Uses L<Data::Validate::Email>::is_email() to validate your email field.

=cut

sub _validate_type_email {
    my ($self, $input, $info) = @_;
    my $path = $self->_troglodyne_path($info);
    return "$path ain't no email I never heard of pardner" unless Data::Validate::Email::is_email($input);
    return;
}

# Build the path the module usually does for errors
sub _troglodyne_path {
    my ($self, $input) = @_;
    return "$input->{base_url}/".join('/', @{$input->{path}});
}

1;
