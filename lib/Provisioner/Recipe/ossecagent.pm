package Provisioner::Recipe::ossecagent;

#ABSTRACT: Run the OSSEC agent on a guest, and send what only the guest can find out to the manager on its collector.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Cookbook();
use Provisioner::Utils();

=head1 NAME

Provisioner::Recipe::ossecagent - the agent of OSSEC, for the manager that
L<Provisioner::Recipe::ossec> runs on the collector.

=head1 SYNOPSIS

Nobody names this recipe.  L<Provisioner::Recipe::logshipper> puts it in its
C<required_recipes> when the collector runs the manager, as C<watches> in
L<Provisioner::Recipe::ossec> decides:

    _base:
        logshipper:
            host: logs.example.test

=head1 DESCRIPTION

The manager reads every line that the guest logs.  This agent adds what the
guest cannot log, because it needs facts that only the guest has.  For now that
is F<root_access>, which the agent runs every five minutes.  The rule for its
output is in L<Provisioner::Recipe::ossec/The rules that replace the log
watchers>.

The agent reads no log file, because the manager already has every line from
the stream.  If it read them too, the manager would raise each alert twice.

The agent runs rootcheck in place of rkhunter, which
L<Provisioner::Recipe::cron> leaves off the guest, and syscheck.  Each scans
what the configuration of the package names.  The manager mails what rootcheck
finds, and the alerts of syscheck go to the dashboard only.  See L<Provisioner::Recipe::ossec/The rules that replace the log watchers>.

The agent sends to the manager on 1514/udp, at the address that the ip pool
assigns the manager.  When the pool assigns it none, the build looks up the
address of the name on the guest, after the guest has resolvers.  The agent
takes an address and not a name, because the
F<ossec.conf> of the package names an example address in C<server-ip>.  The
fragment replaces that setting.  A C<server-hostname> beside it would leave the
example address in the file.

=head2 The key

The manager issues the key of the agent, and C<bin/provision> places it in
F</etc/ossec-client.keys.b64> before the makefile starts.  The makefile
decodes it into F</var/ossec/etc/client.keys>.  See
L<Provisioner::Recipe::ossec/The agents>.  So the manager must be up before the
guest builds, and C<manager> is not a weak field.

=head2 configd makes ossec.conf

As on the manager, L<Provisioner::Recipe::configd> adopts the F<ossec.conf> of
the package as F<ossec.conf.d/00-original>, and this recipe writes
F<ossec.conf.d/50-ossecagent>.

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

True.  One agent runs on the machine, under the name of the machine, with one
F<client.keys>.  Only the domain that is its own machine holds the key, as
C<grants> says, so the build of a tenant does not replace it, and the removal
of a tenant does not revoke it.  The global half runs once, from the host.

=cut

sub is_multi_tenant { return 1 }

=head2 %settings = $recipe->machine_wide(%opts)

C<manager>, because the one agent of the machine sends to one manager.  See
L<Provisioner::Recipe/machine_wide>.

=cut

sub machine_wide {
    my ( $self, %opts ) = @_;
    return ( manager => $opts{manager} );
}

=head2 @names = $recipe->exclusive_on_machine_with()

C<ossec>.  The package of the agent conflicts with the package of the manager,
so a machine has one or the other.  The manager reads the logs of its own
machine from the stream, and needs no agent there.

=cut

sub exclusive_on_machine_with {
    return qw{ossec};
}

=head2 %args = $recipe->args()

=over 4

=item * C<manager>: the guest that runs the manager, which issues the key.

=back

=cut

sub args {
    return (
        type       => 'object',
        required   => ['manager'],
        properties => {
            manager => {
                type        => 'string',
                description => 'The guest that runs the OSSEC manager.  It issues the key of this agent, so it must be up before this guest builds.  logshipper sets it to its host.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with C<manager_ip>, the address that the ip pool assigns
C<manager>, or empty when the pool assigns it none.  Then the build looks up
the address of C<manager> on the guest.  Also adds C<agent>, the name of the
agent, which is the machine of C<domain>.  Dies when C<manager> is a URL.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{agent} = Provisioner::Cookbook->machine_of( $opts{domain} );

    my ( $kind, $address ) = Provisioner::Utils::fleet_address( $opts{manager}, domain => $opts{domain}, ipmap => $opts{ipmap} );
    die "The OSSEC agent of $opts{domain} sends to a host, and '$opts{manager}' is a URL.\n" if $kind eq 'url';

    $opts{manager_ip} = $kind eq 'address' ? $address : q{};
    return %opts;
}

=head2 @grants = $recipe->grants($domain, %opts)

The key of the agent of the machine, which the C<ossec> recipe of C<manager>
issues, when C<$domain> is its own machine.  Nothing for a tenant, whose
machine holds the key for it.

C<bin/destroy> asks with the configuration as the file holds it, which names
no C<manager>, because logshipper adds this recipe.  So the manager is then
the one that L<Provisioner::Recipe::ossec/manager_of> finds, and the key is
revoked when the guest goes away.

=cut

sub grants {
    my ( $self, $domain, %opts ) = @_;
    return () unless Provisioner::Cookbook->machine_of($domain) eq $domain;

    my $manager = $opts{manager} // Provisioner::Cookbook->load('ossec')->manager_of($domain);
    return () unless defined $manager;
    return { recipe => 'ossec', guest => $manager, client => $domain };
}

=head2 %required = $recipe->required_recipes(%opts)

C<configd>, which makes F<ossec.conf>.

=cut

sub required_recipes {
    return ( configd => sub { ( languages => ['ossec'] ) } );
}

=head2 @hosts = $recipe->fetch_hosts()

The archive of Atomicorp, as for the manager.

=cut

sub fetch_hosts {
    return Provisioner::Cookbook->load('ossec')->fetch_hosts();
}

=head2 @classes = $recipe->cache_classes()

The archive, as an apt repository.

=cut

sub cache_classes {
    my ($class) = @_;

    return map { $class->apt_repo_classes($_) } $class->fetch_hosts();
}

=head2 %files = $recipe->template_files()

The fragment of F<ossec.conf> and the firewall profile.

=cut

sub template_files {
    return (
        'ossecagent.conf.tt'     => 'ossecagent.conf',
        'ossecagent.ufw.conf.tt' => 'ossecagent_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

Returns the template for the test that runs on the guest.

=cut

sub tests { return ('ossecagent.tt') }

1;
