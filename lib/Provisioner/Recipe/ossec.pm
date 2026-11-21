package Provisioner::Recipe::ossec;

#ABSTRACT: Run an OSSEC manager on the collector, over the stream of the fleet's logs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Cookbook();

=head1 NAME

Provisioner::Recipe::ossec - intrusion detection over the logs that the collector already receives.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~

Nobody needs to name this recipe.  L<Provisioner::Recipe::logcollector>
requires it, so every collector runs the manager.  For dashboards over its
alerts, see L<Provisioner::Recipe::grafanaossec>.

=head1 DESCRIPTION

OSSEC is a host intrusion detection system.  Its manager decodes log lines,
matches them against rules, and raises an alert with a level from 0 to 15 for
each match.  This recipe runs the manager on the collector and gives it every
message of the fleet.  It keeps each alert in F</var/ossec/logs/alerts>, and
mails the alerts of the rules that replace the log watchers.

=head2 The path of a message

=over 4

=item 1. L<Provisioner::Recipe::logcollector> receives the message from a guest,
and copies it to C<127.0.0.1:port> as a line of text.  This recipe asks for that
copy through C<forward_text>, because the decoders of OSSEC find nothing in
RFC5424, the format of the other C<forward>.

=item 2. The syslog listener of the manager reads it.  The manager keeps the
name of the guest from the line, so an alert names the guest and not the
collector.

=item 3. The manager writes each alert to its log of alerts, and mails the
alerts that L</The rules that replace the log watchers> mark for mail.

=back

Every hop is on loopback, so nothing goes on the wire.

=head2 What another recipe can add

This recipe sends its alerts nowhere else.  A recipe that consumes them adds
its own fragment to F<ossec.conf.d>, as L</configd makes ossec.conf> says.  It
can add an output there, such as C<syslog_output>, and turn on the daemon of
the manager that serves it.  L<Provisioner::Recipe::grafanaossec> does that.
Such an output must not go back through rsyslog.  If it did, the collector
would copy each alert to the manager like any other message, and the manager
could raise an alert on its own alert.

=head2 The agents

The stream carries what a guest logs, and not what only the guest can find
out.  L<Provisioner::Recipe::ossecagent> runs the agent of OSSEC on a guest for
that.  The agent sends its events to the manager on port 1514/udp, which this
recipe opens in the firewall.  Each message is encrypted with the key of its
agent.

The manager issues each key as a grant, as C<grants> in
L<Provisioner::Recipe> describes.  C<bin/provision> runs
F</usr/local/sbin/ossec-agent-key> here before the makefile of the guest
starts, and places the key on the guest.  Each build of the guest gets a new
key, and the old agent of that name is removed.  The manager counts the
messages of each agent, and refuses a message whose count is not higher than
the last one.  A rebuilt agent counts from zero again, so the old key would
not work.  C<bin/destroy> runs F</usr/local/sbin/ossec-agent-revoke>, which
removes the agent of the guest.

The keys are in F</var/ossec/etc/client.keys>, which C<remote_prepare> and
C<remote_files> salvage when the collector is built again, and C<restores> puts
back.  Without the salvage, a new collector knows no agent until each guest is
built again.  The agents keep their counts, which are higher than any that the
new manager has seen, so it takes their messages.  The salvage is in the data
directory of the domain, as the keys of L<Provisioner::Recipe::letsencrypt>
are.  A key there lets its holder send events to the manager in the name of
that one guest.

remoted exits when F<client.keys> names no agent, and the listener of the
stream stops with it.  So the build adds an agent named
C<manager-placeholder>, which nothing runs, when the file has none.

=head2 What is not on yet

Active response is off.  fail2ban stays, and the manager blocks nothing.

The manager mails only the alerts of the rules that do the jobs of the log
watchers.  See L</The rules that replace the log watchers>.

syscheck and rootcheck are off on the manager and on the agents.

=head2 The rules that replace the log watchers

L<Provisioner::Recipe::cron> runs four scripts on a guest every five minutes.
They read the system log and mail the admin what they find: segfaults, the OOM
killer, new users, and messages that rsyslog dropped.  F<watchers_rules.xml>
has a rule for each.  The configuration adds it after the rule files of the
package, because each rule is a child of rules in those files.  Each rule mails its alert, as the script mailed its finding, to the
C<admin_email> of the collector, through the mail server on loopback port 25.
No other alert sends mail.

A guest does not run the four scripts when C<watches> is true for it.

The fifth, F<root_access>, needs facts that only the guest has: the uid of its
admin, and the addresses that the keys of root accept.  So the agent runs it,
and the rule raises an alert on what it prints.  When C<watches> is true, cron
does not run it either.

=head2 The package comes from Atomicorp

OSSEC is not in the Ubuntu archive.  Atomicorp, who maintain OSSEC, publish
C<ossec-hids-server> in an archive of their own, and
L<Provisioner::Recipe::Ubuntu::ossec> takes the package from there.  The archive
can be a release behind the source.

=head2 configd makes ossec.conf

OSSEC reads one F<ossec.conf> and has no directory of configuration.  So
L<Provisioner::Recipe::configd> adopts it with the C<ossec> language of
L<Configd>: the file of the package becomes F<ossec.conf.d/00-original>, this
recipe writes F<ossec.conf.d/50-ossec>, and configd merges the two each time
the manager starts.

The rule list comes from the package that way.  OSSEC loads its rule files in
the order of the list, and a rule can name rules in the files before it, so the
files cannot load in the order of a directory.  The list of the package keeps
its order in the merge, and nothing here names a rule file.  When an upgrade of
the package leaves its new file as F<ossec.conf.dpkg-dist>, configd takes it as
the new F<00-original> at the next start.

The file of the package also configures what this recipe does not want, and
the fragment clears each of those with an empty element: its listeners, active
response that blocks addresses in the firewall of the collector, the log files
of its example, a whitelist of private addresses and mail to an example
address.  The fragment then adds the listeners that this recipe wants.

The C<ossec> language reads XML with L<XML::LibXML>, which is not in core perl,
so L<Provisioner::Recipe::Ubuntu::ossec> installs it with the manager.

=cut

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one manager on the machine, and one collector that feeds it.

=cut

sub is_multi_tenant { return 0 }

=head2 $bool = Provisioner::Recipe::ossec->watches($domain)

True when an OSSEC manager of this installation reads every log line of the
machine of C<$domain>, as C<manager_of> decides.

=cut

sub watches {
    my ( $class, $domain ) = @_;
    return defined( $class->manager_of($domain) ) ? 1 : 0;
}

=head2 $collector = Provisioner::Recipe::ossec->manager_of($domain)

The collector whose OSSEC manager reads every log line of the machine of
C<$domain>, or undef when there is none.  There is one when the machine runs
L<Provisioner::Recipe::logshipper> with the selector C<*.*>, and its C<host> is
another domain of this installation.  That domain runs
L<Provisioner::Recipe::logcollector>, which requires this recipe, so it runs
the manager.

A selector that is not C<*.*> can leave out a facility that a rule needs, so
it gives none.  So does a C<host> that is an address or a name outside this
installation, because nothing here says what runs there.  The collector itself
ships nowhere, so it has none either.

=cut

sub manager_of {
    my ( $class, $domain ) = @_;

    my $machine = Provisioner::Cookbook->machine_of($domain);
    my $shipper = Provisioner::Cookbook->domain_config($machine)->{logshipper};
    return unless ref $shipper eq 'HASH' && defined $shipper->{host};

    my %default = Provisioner::Cookbook->defaults('logshipper');
    return if ( $shipper->{selector} // $default{selector} ) ne '*.*';

    my $collector = $shipper->{host};
    return if $collector eq $machine;
    return Provisioner::Cookbook->configures($collector) ? $collector : undef;
}

=head2 %args = $recipe->args()

=over 4

=item * C<port>: the loopback TCP port where the manager reads the copy of the
stream.  It is also the port that the collector sends to.

=back

C<alerts_port> and C<datasource> moved to L<Provisioner::Recipe::grafanaossec>.
The schema here refuses them, so a configuration that still names them here
names the recipe and the field.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                default     => 10514,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback TCP port the OSSEC manager reads the copy of the collector stream on, and the port logcollector is told to copy to.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<logcollector>, with the copy as text that the manager reads, and
C<configd>, which makes F<ossec.conf>.  logcollector requires this recipe too.
See L<Provisioner::Cookbook/Recipes that require each other>.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because this runs before validation.
    my $port = $opts{port} // 10514;

    return (
        logcollector => sub { ( forward_text => ["127.0.0.1:$port"] ) },
        configd      => sub { ( languages    => ['ossec'] ) },
    );
}

=head2 @claims = $recipe->listens(%opts)

The listener of the manager on C<port>, on 127.0.0.1, and the listener of
the agents on 1514/udp, on every address.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as required_recipes does.
    return ( '127.0.0.1:' . ( $opts{port} // 10514 ), '1514/udp' );
}

=head2 %files = $recipe->issue_grant($grant)

The key of the agent of the C<client> of C<$grant>, as
F</etc/ossec-client.keys.b64> on that guest: its line of F<client.keys>, in
base64, because C<bin/provision> takes a secret of one word.  The build of the
agent decodes it into F<client.keys>.  It is outside F</var/ossec>, because the
package gives every file in F</var/ossec/etc> to the group C<ossec> each time
it installs.  The manager on the C<guest> of C<$grant>
makes a new one each time.  See L</The agents>.

=cut

sub issue_grant {
    my ( $self, $grant ) = @_;
    return (
        '/etc/ossec-client.keys.b64' => {
            issue => { guest => $grant->{guest}, command => "/usr/local/sbin/ossec-agent-key $grant->{client}" },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 @commands = $recipe->remote_prepare()

A copy of F</var/ossec/etc/client.keys>, the keys of the agents, in
F</var/lib/ossec-salvage>, because a salvage fetches a directory and not a
file.  The copy stays on the collector, and only root reads it there.  In the
domain directory, the service user could read it.  See L</The agents>.

A guest that does not run the manager yet has no keys, so the command then
does nothing, and creates no directory.  A directory that a failed command
left behind makes F<bin/new_config> refuse the salvage.

=cut

sub remote_prepare {
    return ('if [ -f /var/ossec/etc/client.keys ]; then install -d -m 0700 /var/lib/ossec-salvage && install -m 0600 /var/ossec/etc/client.keys /var/lib/ossec-salvage/client.keys; fi');
}

=head2 %path_map = $recipe->remote_files()

The copy that C<remote_prepare> made.

=cut

sub remote_files {
    return ( '/var/lib/ossec-salvage/' => 'ossec-salvage/' );
}

=head2 %restores = $recipe->restores(%opts)

The keys of the agents, back where the manager reads them, readable by the
manager and nobody else.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    return ( '/var/ossec/etc/client.keys' => { from => "$install_dir/$domain/ossec-salvage/client.keys", owner => 'root:ossec', mode => '0440' } );
}

=head2 %revocation = $recipe->revoke_grant($grant)

The removal of the agent of the C<client> of C<$grant> from the manager.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client = $grant->{client};
    return (
        command => "/usr/local/sbin/ossec-agent-revoke $client",
        doing   => "remove the OSSEC agent of $client",
        done    => "Removed the OSSEC agent of $client",
        stays   => "the key of the OSSEC agent of $client stays on it.  Run ossec-agent-revoke $client there",
    );
}

=head2 @hosts = $recipe->fetch_hosts()

The archive of Atomicorp.

=cut

sub fetch_hosts {
    return (qw{updates.atomicorp.com});
}

=head2 @classes = $recipe->cache_classes()

The archive, as an apt repository.

=cut

sub cache_classes {
    my ($class) = @_;

    return map { $class->apt_repo_classes($_) } $class->fetch_hosts();
}

=head2 %files = $recipe->template_files()

The configuration of the manager, its rules for the log watchers, the scripts
that issue and revoke the keys of the agents, and the firewall profile for the
agents.

=cut

sub template_files {
    return (
        'ossec.conf.tt'         => 'ossec.conf',
        'ossec.rules.tt'        => 'watchers_rules.xml',
        'ossec.agent-key.tt'    => 'ossec-agent-key',
        'ossec.agent-revoke.tt' => 'ossec-agent-revoke',
        'ossec.ufw.conf.tt'     => 'ossec_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

Returns the template for the test that runs on the guest.

=cut

sub tests { return ('ossec.tt') }

1;
