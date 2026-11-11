package Provisioner::Recipe::servicesudo;

#ABSTRACT: sudo without a password for the service user of a domain, for a named list of commands and nothing else.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};
use Trog::Patterns();

=head1 Provisioner::Recipe::servicesudo

=head2 SYNOPSIS

    somedomain:
        _global:
            user: someservice
        servicesudo:
            commands:
                - /usr/bin/systemctl restart someservice
                - /usr/bin/systemctl status someservice
                - /usr/bin/journalctl -u someservice
                - /usr/bin/uptime ""

=head2 DESCRIPTION

This recipe is for a guest where a program runs as the service user with
nobody at the keyboard, such as an agent.  The program needs root for a few
things, and for nothing else.  So the service user gets sudo without a
password for each command in C<commands>, run as root, and for no other
command.

The service user is C<user> in the C<_global> of the domain.  Each command
goes on a line of its own in F</etc/sudoers.d/servicesudo-$user>.  A guest can
hold several domains, so the file is named for the user.  C<visudo -cf> checks
the file before C<install> puts it there with mode C<0440>, as
L<Provisioner::Recipe::sssd> does.  sudo refuses to run at all while a file in
F<sudoers.d> does not parse.

With an empty C<commands>, the file holds a comment and no grant.  It is still
installed, so a provision with an empty list takes back a grant that an earlier
provision made.

=head2 FIELDS

=over 4

=item C<commands>

A list of commands, each in the syntax of F<sudoers>: the absolute path of the
program, then the arguments, if any.  The default is an empty list.

sudo matches the arguments as they are written.  A command with no arguments
allows B<any> arguments, so C</usr/bin/systemctl> alone is root.  Write
C</usr/bin/systemctl restart someservice> to allow that one call, and the
path followed by C<""> alone to allow the program only with no arguments.

The schema refuses the obvious mistakes: a path that is not absolute, which
includes C<ALL> and a negation, a newline, a comma, which starts a second
command, and an empty argument.  It does not judge the rest of the sudoers
syntax.  C<visudo -cf> on the guest refuses a file that sudo cannot read, and
the guest test asks C<cvtsudoers> what sudo makes of the installed file.  So a
file that grants other than C<commands> fails the build.  A wildcard or a
C<^...$> argument is a pattern to sudo, and so allows more than the operator
wrote.  The schema allows both, because the operator can mean them.

=back

=head2 A domain with no service user

If the domain names no C<user>, C<user> falls back to C<admin_user>, as
L<Provisioner::Recipe/validate> says.  This recipe then installs nothing, and
its guest test skips.  The program runs as the admin, whom F<bin/new_config>
gives sudo for everything, so a list of commands can add nothing to it.  A
recipe that needs its service user to run a command as root can require this
recipe, and a domain without a service user still builds.  The same holds for
a domain that names the admin as its C<user>.

=cut

# An absolute path, and the words of its arguments, with no comma.
my $COMMAND = qr/\A \/ [^\s,]+ (?: [ ] [^\s,]+ )* \z/;

sub args {
    return (
        type       => 'object',
        properties => {
            commands => {
                type        => 'array',
                default     => [],
                uniqueItems => 1,
                items       => {
                    type    => 'string',
                    pattern => "$COMMAND",
                },
                description => 'Commands, in sudoers syntax, that the service user may run as root with sudo and no password.  An absolute path and its fixed arguments.  A command with no arguments allows any.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Dies when C<user> is not C<admin_user> and is not a plain account name.  It
goes into a sudoers line and into the name of a file in F<sudoers.d>, and sudo
skips a file whose name has a dot in it.  C<user> is a global, which the schema
of a recipe does not declare a second time, so the check is here.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    return %opts if $opts{user} eq $opts{admin_user};
    die "servicesudo: the user of $opts{domain}, $opts{user}, is not a name that a sudoers line and the name of a file in sudoers.d can both hold.\n"
      unless $opts{user} =~ $Trog::Patterns::ACCOUNT_NAME;

    return %opts;
}

=head2 @commands = unit_commands(@units)

A function, not a method.  The commands that let the service user restart each
systemd unit of C<@units> and ask for its status:
C</usr/bin/systemctl restart $unit> and C</usr/bin/systemctl status $unit>.

A recipe that installs a unit that runs as C<user> requires this recipe with
these commands for its own units, and for no other.  Name each unit with its
suffix, such as C<example.test.service>.  sudo matches the arguments as they
are written, so a program that calls sudo writes the unit the same way, and
C</usr/bin/systemctl> by its full path.

=cut

sub unit_commands {
    my (@units) = @_;
    return map { ( "/usr/bin/systemctl restart $_", "/usr/bin/systemctl status $_" ) } @units;
}

sub template_files {
    return ( 'servicesudo.sudoers.tt' => 'servicesudo.sudoers' );
}

sub tests {
    return qw{servicesudo.tt};
}

1;
