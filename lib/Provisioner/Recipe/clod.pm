package Provisioner::Recipe::clod;

#ABSTRACT: Install and run App::Clod, the hub-and-spoke GitHub bot.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use B();
use Digest::SHA();
use Encode();
use Mojo::JSON();
use Text::Xslate();

use Provisioner::Packager();
use Provisioner::Recipe::claude();
use Provisioner::Recipe::servicesudo();
use Provisioner::Utils();
use Trog::Patterns();

# One copy for args and fetch_hosts, so that two copies do not drift apart.
our $DEFAULT_REPO = 'https://github.com/Troglodyne-Internet-Widgets/App-Clod.git';

# One copy for the grant, the fragment and clod.conf.  See THE SYSTEM PACKAGES.
our $INSTALLER = '/usr/local/sbin/clod-install-packages';

=head1 Provisioner::Recipe::clod

=head2 SYNOPSIS

    somedomain:
        clod:
            # The GitHub login of the bot, and a classic token of that
            # account with the repo scope, which the inbox also needs.
            bot:          "yourname-bot"
            github_token: "secret:github/yourname-bot/password"

            # The long-lived OAuth token that `claude setup-token` makes on a
            # workstation.
            claude_oauth_token: "secret:claude/yourname-bot/password"

            # The repositories that the bot works on, as Owner/Name.  Give
            # spokes, spoke_orgs or both.
            spokes:
                - "otherorg/app"

            # Organizations whose public repositories are all spokes, except
            # forks and archived ones.  App::Clod lists them every fifteen
            # minutes, so a new repository needs no provision.
            spoke_orgs:
                - "yourorg"

            # Whose assignments, review requests and mentions the bot acts on.
            authorized_users:
                - "yourname"

            # The users and organizations whose repositories are ours.  A fix
            # that belongs anywhere else goes back to a person.
            owners:
                - "yourorg"

            # HTTP basic authentication for the health page.  The hash is the
            # output of: printf %s 'the password' | sha256sum
            dashboard_password: "secret:clod/dashboard/password"

            # Optional.
            dashboard_user: "admin"

            # Let an authorized user have the bot make a repository in an
            # organization of spoke_orgs, one per request.  The token must be
            # able to make repositories there.
            create_repos: true

            # How many follow-up issues one request may file.  0 turns it off.
            follow_up_max: 3
            workers:        2
            spoke_modules:
                - "Test2::V0"

            # Permission rules that the runs which change a repository get,
            # beyond the defaults of App::Clod.  The triage run never does.
            extra_tools:
                - "Bash(bin/provision:*)"

            # Told to every spoke run, and to triage, so that it knows how
            # each spoke tests.
            spoke_prompt: |
                Run prove -lr t before you commit.

            # Repositories of which every spoke run gets a fresh worktree of
            # its own, such as a tool that the runs use.
            tool_spokes:
                - "yourorg/tool"

            # The account that every claude run runs as, so that the agent
            # cannot read the token of the bot.  See THE AGENT ACCOUNT.
            agent_user: "clod-agent"

=head2 DESCRIPTION

Installs L<App::Clod|https://github.com/Troglodyne-Internet-Widgets/App-Clod>
and runs it as two systemd services, as the service C<user> of the domain:

=over 4

=item * C<clod-E<lt>domainE<gt>> runs C<clod daemon>.  It serves the health
page and Minion::Admin on a unix socket, and L<Provisioner::Recipe::nginxproxy>
serves that socket on port 443.  Port 80 redirects to it.

=item * C<clod-worker-E<lt>domainE<gt>> runs C<clod minion worker>.  It reads
the inbox of the bot and does the work, with C<workers> jobs at a time.

=back

The services run from a checkout of C<repo_url>.  L<Provisioner::Recipe::perl>
installs what the checkout needs, with its C<dzil> step.  That step also
installs the author dependencies of App::Clod, which include C<perltidy>,
C<perlcritic> and the Troglodyne policies.  The git hooks of the spokes run
those tools when the bot commits in a C<git worktree>.

To add a spoke, give the bot write access to it.  If the bot is a member of
an organization in C<spoke_orgs>, with write access through a team, a new
public repository there needs nothing else.  Otherwise add it to C<spokes>
and provision again.  If the tests of a spoke need modules
that App::Clod does not, name them in C<spoke_modules>.

L<Provisioner::Recipe::claude> installs the C<claude> program and the settings
in the directory of the domain.  That directory is the C<HOME> of both
services, so every C<claude> run of the bot uses those settings and the
plugins that they enable.  Set C<user> for the domain, so that the bot runs as
an account without the sudo of the admin.  The bot runs unattended, and a run
that goes wrong can do whatever its account can.  The claude recipe gives
F<.claude> to C<user> when the domain names one, and to the admin only when
it does not.

Those settings apply to every C<claude> run in that C<HOME>, and so to the
triage run too, which only reads.  A permission for the runs that change a
repository goes in C<extra_tools> instead, which App::Clod gives to those
runs alone.

The layout on the guest:

    [install_dir]/[domain]/App-Clod/    the checkout
    [install_dir]/[domain]/clod.conf    the configuration, 0640 root:[user]
    [install_dir]/[domain]/clod.env     GH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN, 0640 root:[user]
    [install_dir]/[domain]/clod-state/  the Minion database
    [install_dir]/[domain]/workspace/   the mirrors, the work trees and the hub of the bot
    [install_dir]/[domain]/run/         the socket, 2750 [user]:www-data

The Minion database holds every job, the history on the health page, and the
claims that stop the bot from taking one notification twice.  So it survives a
rebuild of the guest.  See C<remote_prepare>.  The workspace does not, because
the bot fetches the mirrors again.

=head2 THE AGENT ACCOUNT

Without C<agent_user>, every C<claude> run of the bot runs as C<user>, the
account of the worker.  App::Clod keeps C<GH_TOKEN> out of the environment of
claude, but a process can read F</proc/$pid/environ> of every process of its
own account, and the worker has the token in its environment.  The default
tools of a spoke run include C<Bash(perl:*)>, so the agent could read it.

With C<agent_user>, the bot runs claude as that account instead, through
sudo.  The account cannot read the environment of the worker, F<clod.env> or
F<clod.conf>.  The recipe:

=over 4

=item * Hands the name to L<Provisioner::Recipe::claude> as C<restricted_user>.
That recipe makes the account and its home, C<agent_home>, with the plugins
and settings of the agent of the domain, but without its bot.  See
L<Provisioner::Recipe::claude/A RESTRICTED AGENT>.

=item * Lets C<user> run any command as C<agent_user>, with C<SETENV> and no
password, in F</etc/sudoers.d/clod-E<lt>userE<gt>>.  The grant goes from the
account of the worker down to an account that holds less, so it gives the
worker nothing that it does not already have.  C<SETENV> lets App::Clod pass the
names of its C<env> through the environment, never through the argument list,
which C<ps> shows to every account.  The file also sets the umask of a
command that runs as C<agent_user> to C<0007>, because sudo combines its own
umask with that of the worker.  Without C<agent_user>, the file holds no
grant, so a provision takes back the grant of an earlier one.

=item * Gives the workspace to the group of C<agent_user>, setgid, with mode
C<2770>, and puts C<user> in that group.  The worker gets C<UMask=0007>.  So
claude can commit in a work tree that the worker made, and the worker can push
the commit and remove the work tree.  The group of C<user> stays the group of
F<clod.env> and F<clod.conf>, and the agent is not in it.  F<clod-share.sh>
does this in the postrun, before the services restart, because the target of
the claude recipe runs after this one, and makes the account.

=item * Gives the Claude token to C<agent_user> alone, in
F<E<lt>agent_homeE<gt>/.claude-token>, mode 0400.  F<clod-claude.sh> in the
directory of the domain reads it and runs claude, and is C<bin> of the
C<claude> section of F<clod.conf>.  So the token never goes through sudo,
which logs each variable that it passes, with its value.  F<clod.env> then
holds no Claude token, because the worker needs none.  F<clod-share.sh>
installs the token, because the account exists only in the postrun.

=item * Writes C<run_as> into the C<claude> section of F<clod.conf>.

=back

If the agent builds guests to test on, with L<Provisioner::Recipe::trogrunner>
on the same domain, name C<agent_user> as the C<provision_user> of that recipe
too.  Then the agent gets the key that the hypervisors trust, and the worker
does not.  See L<Provisioner::Recipe::trogrunner/THE PROVISIONING ACCOUNT>.

C<deps> is in L<Provisioner::Recipe::Ubuntu::clod>.

=cut

# A word that goes into clod.conf between single quotes, and into a quoted
# string of the guest test, and the GitHub logins and repositories, which fit it.
my %NAME  = ( type => 'string', pattern => "" . qr/\A [[:alnum:]_.-]+ \z/ );
my %LOGIN = ( type => 'string', pattern => "$Trog::Patterns::GITHUB_LOGIN" );
my %REPO  = ( type => 'string', pattern => "$Trog::Patterns::GITHUB_REPO" );

# A permission rule of Claude Code: a tool, or a tool and what it may do.
# perl_string quotes it, so this only holds it to that shape, on one line.
my $RULE = qr/\A [[:alpha:]] [[:alnum:]_]* (?: [(] [^\n\r'"\\]+ [)] )? \z/;

sub args {
    return (
        type     => 'object',
        required => [qw{bot github_token claude_oauth_token dashboard_password}],
        anyOf    => [ { required => ['spokes'] }, { required => ['spoke_orgs'] } ],

        # App::Clod makes a repository in an org of spoke_orgs, and dies without one.
        allOf      => [ { anyOf => [ { properties => { create_repos => { type => 'boolean', enum => [Mojo::JSON::false] } } }, { required => ['spoke_orgs'] } ] } ],
        properties => {
            repo_url    => { type => 'string', default => $DEFAULT_REPO, description => 'Where to clone App::Clod from.' },
            repo_branch => { type => 'string', default => 'master',      description => 'The branch of repo_url that the services run.' },

            bot                => { %LOGIN, description => 'The GitHub login of the bot.' },
            github_token       => { type => 'string', 'x-secret' => 1,                               description => 'A classic token of the bot account, with the repo scope.' },
            claude_oauth_token => { type => 'string', 'x-secret' => 1,                               description => 'The long-lived OAuth token that claude setup-token makes.' },
            bot_email          => { type => 'string', pattern    => "$Trog::Patterns::COMMIT_EMAIL", description => 'The address of the commits of the bot.  Unset is the GitHub no-reply address of the bot.' },

            spokes => {
                type        => 'array',
                minItems    => 1,
                items       => {%REPO},
                description => 'The repositories that the bot works on, as Owner/Name.',
            },
            tool_spokes => {
                type        => 'array',
                default     => [],
                items       => {%REPO},
                description => 'Repositories, as Owner/Name, of which every spoke run gets a fresh worktree of its own.',
            },
            spoke_orgs => {
                type        => 'array',
                minItems    => 1,
                items       => {%LOGIN},
                description => 'Organizations whose public repositories are spokes, except forks and archived ones.  App::Clod lists them every fifteen minutes.',
            },
            authorized_users => { type => 'array', default => [], items => {%LOGIN}, description => 'The logins whose assignments, review requests and mentions the bot acts on.  The bot ignores everyone else.' },
            owners           => { type => 'array', default => [], items => {%LOGIN}, description => 'The users and organizations whose repositories are ours.  A fix that belongs anywhere else goes back to a person.' },

            dashboard_user     => { %NAME, default => 'admin', description => 'The user name of HTTP basic authentication for the health page.' },
            dashboard_password => { type => 'string', 'x-secret' => 1, minLength => 1, description => 'The password of the health page.  clod.conf gets only its SHA-256.' },

            workers       => { type => 'integer', default => 2,  minimum     => 1, description => 'How many jobs the worker runs at once.  Each job can be a claude run.' },
            poll_interval => { type => 'integer', minimum => 60, description => 'The least number of seconds between two reads of the inbox.  Unset is the default of App::Clod.' },
            create_repos  => { type => 'boolean', default => 0,  description => 'Whether an authorized user can have the bot make a new repository, in an organization of spoke_orgs, one per request.  Needs spoke_orgs, and a token that may make repositories there.' },
            follow_up_max => { type => 'integer', minimum => 0,  description => 'How many follow-up issues one request may have the bot file.  0 turns it off.  Unset is the default of App::Clod.' },
            spoke_modules => { type => 'array',   default => [], items       => { type => 'string' }, description => 'Modules that the tests of the spokes need, beyond what App::Clod needs.  The perl recipe installs them.' },

            extra_tools => {
                type        => 'array',
                default     => [],
                items       => { type => 'string', pattern => "$RULE" },
                description => 'Claude Code permission rules, such as Bash(bin/provision:*), that App::Clod adds to its allowed_tools for the runs that change a repository, and never for triage.',
            },
            spoke_prompt => { type => 'string', minLength => 1,                               description => 'Text that App::Clod appends to the system prompt of every spoke run, and shows to triage, so that it knows how each spoke tests.' },
            agent_user   => { type => 'string', pattern   => "$Trog::Patterns::ACCOUNT_NAME", description => 'The account that every claude run of the bot runs as, through sudo, so that the agent cannot read the token of the bot.  See THE AGENT ACCOUNT.' },
        },
    );
}

=head2 THE LOCAL LIB

The C<perl> recipe installs what the checkout needs into the perl of the host,
which root owns.  So the bot, which runs as C<user>, could not install what a
new version of itself needs, nor upgrade a module with a newer release.  A
sudo grant for cpm would be root, because cpm takes any mirror.

So the recipe makes a local lib, F<perl5> in the directory of the domain, that
C<user> owns, and names it as C<local_lib> in F<clod.conf>.  Both units put it
first on C<PERL5LIB>, and its F<bin> first on C<PATH>, so a module there wins
over the one of the host.  In the postrun, before the units start,
F<clod-deps.sh> runs C<clod deps install> as C<user>, which installs every
module that the checkout needs into it.  cpm installs a module into a local
lib even when the perl has it, so the local lib holds a copy of each.  From
then on the dashboard of the bot installs and upgrades them there, with no
sudo.  See L<App::Clod::Deps>.

The recipe also names both units in C<restart_units>, which the bot restarts
after an update, through the sudo grant of C<servicesudo>.

The perl of the host still gets every module too, from the C<dzil> step of
C<cpan_deps>.  C<clod deps install> needs them to run at all, before the local
lib has any.  The recipe adds C<App::cpanoutdated> there, for C<clod deps
outdated>.

=head2 THE AGENT LIB

The agent runs C<perlcritic>, C<perltidy> and the tools of Devel::NYTProf in a
spoke, and in its hooks.  The policies that C<perlcritic> needs are those that the critic
profiles of the standards name, and the standards can name a new one at any
time.  So they go into a second local lib, F<agent-perl5> in the directory of
the domain, which the bot keeps, rather than into the perl of the host, where
only a provision could add one.  It is C<agent_lib> in F<clod.conf>, and
App::Clod puts it first on the C<PERL5LIB> and C<PATH> of every claude run.
C<clod deps install> fills it in the postrun, with the rest.  See
L<App::Clod::Deps>.

C<user> owns it, and its group is C<agent_user>, or C<admin_user> without one.
The fragment makes it with the group of C<admin_user>, because the C<claude>
target makes the agent account after the fragment runs.  F<clod-share.sh>
gives it to C<agent_user> in the postrun, before C<clod deps install>.
Its mode is C<2750>, so what the bot installs there takes that group, and
App::Clod installs with C<umask 0027>.  So the agent may read the tools and
not change them.

=head2 THE SYSTEM PACKAGES

A spoke declares the system packages that it needs in F<metamerge.yml>, and
App::Clod shows a spoke that needs packages which the guest lacks, with a
button that installs them.  See C<system_packages> in L<App::Clod::Config>.
The bot runs as C<user>, and only root installs a package.

So the recipe installs F</usr/local/sbin/clod-install-packages>, root's, mode
0755, and lets C<user> run it as root with sudo, any arguments and no
password, through C<servicesudo>.  It takes the names of the packages as its
arguments:

    sudo -n /usr/local/sbin/clod-install-packages ffmpeg libmagic-dev

It refuses the whole call when any argument is not a plain package name, or
when there is none, with exit 2 and a message on standard error, and runs nothing.
What a plain name is comes from the packager of the guest, which takes it from
L<Dist::Conformance::Check::SystemPackages>, so the installer refuses what a
declaration may not hold.  For deb that rules out a name that ends in C<->,
which apt reads as a removal, an option such as C<-y>, a version, an archive,
a file and a second name in one argument.  So the grant can install a package
from the archives that the guest already trusts, and do nothing else.

A spoke can also declare the third-party archives that its packages come
from.  Then the bot writes them, as App::Clod resolves them for the guest, into
a file, one JSON object for each line, as C<conformance packages --sources>
prints them, and names it first:

    sudo -n /usr/local/sbin/clod-install-packages --sources-file FILE ffmpeg

Each object is a source of L<Provisioner::Packager::Deb/A source>, with
C<fingerprint>, the 40 hex digits of the fingerprint of its key, beside it.
The service user writes the file, so the installer trusts none of it.  It
refuses the whole call, with exit 2, before it changes anything, when:

=over 4

=item * a line is not JSON, or a source has a field that a source does not, or
lacks one, or one is not what a source holds: a name of lowercase letters,
digits, dots and dashes; an C<http> or C<https> URI and key URL; one word of
printable ASCII for each suite, component and architecture; and an integer
priority for a pin.  So no value can end a line of a file of apt, or name a
file outside the directories below.

=item * two sources have one name.

=item * the key does not fetch, is not a PGP key, or holds other than one
primary key, whose fingerprint, as C<gpg --show-keys> reads it, is not
C<fingerprint>.

=item * a file that a source would write is there already with other content,
such as the sources of the distribution.  The same content is not refused, so
a source that the guest has already is no reason to refuse.

=back

Otherwise it writes the files that L<Provisioner::Packager::Deb/files> writes
at first boot, the key under F</etc/apt/keyrings>, the deb822 F<.sources>
with C<Signed-By> and the pin, mode 0644, and runs the C<update_command> of
the packager for each source.  When one fails, it exits with that status and
installs nothing.

Then it runs the C<install_command> of the packager, without recommends and
without a prompt, with the names after it.  It prints what the packager
printed, and exits with its status.  Its C<PATH> starts with the links of
F<scripts/serial_apt>, so each C<apt-get> waits for any other apt that the
build runs, rather than failing on the lock of the lists.

The installer runs on the system perl, which has no checkout of this
repository, so it holds its own copy of how a source becomes files.
F<t/Provisioner-Recipe-clod.t> holds the copy to what
L<Provisioner::Packager::Deb> writes.

F<clod.conf> gets C<system_packages>, with the packager of the guest, from the
subclass of the recipe for its distribution, and the path of the installer.

=head2 $packager = $recipe->distro_packager()

The name of the packager of the distribution, such as C<deb>.  The subclass of
each distribution answers it, from its distro recipe.  This class dies.

=cut

sub distro_packager {
    my ($self) = @_;
    die( ( ref $self || $self ) . " does not say which packager its distribution has, so clod cannot install the packages of a spoke there.\n" );
}

=head2 %required = $recipe->required_recipes(%opts)

C<perl>, which installs what the checkout needs, C<App::cpanoutdated>, the
programs that App::Clod lets a run use, and C<spoke_modules>.  Those programs
are C<perlcritic>, C<perltidy>, C<nytprofhtml> and C<nytprofmerge>, from
Perl::Critic, Perl::Tidy and Devel::NYTProf.  Perl::Critic and Perl::Tidy also arrive
through the author dependencies of the checkout, but only by chance, so the
recipe names them.
C<nginxproxy>, which serves the socket.  C<claude>, which installs the program
that does the work, and makes the C<agent_user> as its C<restricted_user>.
C<servicesudo>, which lets the service user restart both units, and ask for
their status, with sudo, as
L<Provisioner::Recipe::servicesudo/unit_commands> says.  It also lets the
service user run C</usr/bin/systemctl restart --no-block> for each unit, which
is how the dashboard restarts the bot after an update.  The update runs in the
worker, so a restart of the worker that waited would wait for itself.  It also lets the service user run the
installer of L</THE SYSTEM PACKAGES> with any arguments.

=cut

sub required_recipes {
    return (
        # The perl target runs after this fragment makes the checkout, and
        # before the postrun starts the services.  See cpan_deps in
        # Provisioner::Recipe::perl.  Before validation, so no default yet.
        perl => sub {
            my (%opts) = @_;
            my @modules = @{ $opts{spoke_modules} // [] };
            return (
                cpan_deps => [
                    { dzil    => "$opts{install_dir}/$opts{domain}/App-Clod" },
                    { install => [qw{App::cpanoutdated Perl::Critic Perl::Tidy Devel::NYTProf}] },
                    ( @modules ? { install => \@modules } : () ),
                ],
            );
        },
        nginxproxy  => sub { return ( proxy_uri => 'run/clod.sock' ) },
        servicesudo => sub {
            my (%opts) = @_;
            my @units = ( "clod-$opts{domain}.service", "clod-worker-$opts{domain}.service" );
            return ( commands => [ Provisioner::Recipe::servicesudo::unit_commands(@units), ( map { "/usr/bin/systemctl restart --no-block $_" } @units ), $INSTALLER ] );
        },
        claude => sub {
            my (%opts) = @_;
            return defined $opts{agent_user} ? ( restricted_user => $opts{agent_user} ) : ();
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<agent_home>, the home that L<Provisioner::Recipe::claude> makes for
C<agent_user>, when the domain names one.

Adds C<packager>, from C<distro_packager>, and from its L<Provisioner::Packager>,
C<package_name>, C<install_command> and C<update_command>, which the installer
of L</THE SYSTEM PACKAGES> holds.  Adds C<installer>, its path.

Replaces C<dashboard_password> with C<dashboard_password_sha256>, the SHA-256 of
its C<UTF-8> bytes in lowercase hex, which is what F<clod.conf> holds.  So the
password is a secret of the store like every other, and it reaches no template.

Dies when C<user> is not a plain account name.  It goes into a sudoers line
and into the name of F</etc/sudoers.d/clod-E<lt>userE<gt>>, and sudo skips a
file whose name has a dot in it.  C<user> is a global, which the schema of a
recipe does not declare a second time, so the check is here.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    die "clod: the user of $opts{domain}, $opts{user}, is not a name that a sudoers line and the name of a file in sudoers.d can both hold.\n"
      unless $opts{user} =~ $Trog::Patterns::ACCOUNT_NAME;
    $opts{agent_home} = Provisioner::Recipe::claude::->restricted_home( %opts, restricted_user => $opts{agent_user} ) if defined $opts{agent_user};
    $opts{local_lib}  = "$opts{install_dir}/$opts{domain}/perl5";
    $opts{agent_lib}  = "$opts{install_dir}/$opts{domain}/agent-perl5";

    my $packager = Provisioner::Packager->named( $opts{packager} = $self->distro_packager );
    $opts{package_name}    = $packager->package_name;
    $opts{install_command} = [ $packager->install_command ];
    $opts{update_command}  = [ $packager->update_command('{sources}') ];
    $opts{installer}       = $INSTALLER;

    # App::Clod hashes the bytes of the password that basic authentication sends.
    $opts{dashboard_password_sha256} = Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', delete $opts{dashboard_password} ) );
    return %opts;
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Runs F<clod-salvage.sh>, which copies the Minion database into
F<.clod-salvage> with the C<.backup> of C<sqlite3>.  The worker writes the
database all the time, so a plain copy can take half of a transaction.  On a
guest without the database, the command fails, and the salvage keeps what it
had.

=cut

sub remote_prepare {
    my ( $self, $install_dir, $domain ) = @_;
    return ("$install_dir/$domain/clod-salvage.sh");
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

The copy that C<remote_prepare> made.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ( "$install_dir/$domain/.clod-salvage/" => 'clod-salvage/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvaged database goes back to F<clod-state>, owned by the service C<user>.

=cut

sub restores {
    my ( $self, %opts ) = @_;
    my ( $install_dir, $domain, $admin_user ) = @opts{qw{install_dir domain admin_user}};
    my $user = $opts{user} // $admin_user;
    return ( "$install_dir/$domain/clod-state/minion.db" => { from => "$install_dir/$domain/clod-salvage/minion.db", owner => "$user:$admin_user", mode => '0640' } );
}

=head2 %formatters = $recipe->formatters()

C<perl_string>, which F<clod.conf.tt> quotes free text with.  L<B/perlstring>
escapes every quote, C<$>, C<@>, backslash and control character, so no text
can end the string or interpolate into it.  It is raw, so Xslate does not
escape it for HTML on top.

=cut

sub formatters {
    return ( perl_string => Text::Xslate::html_builder( sub ($text) { return B::perlstring($text) } ) );
}

sub template_files {
    return (
        'clod.conf.tt'             => 'clod.conf',
        'clod.env.tt'              => 'clod.env',
        'clod.service.tt'          => 'clod.service',
        'clod-worker.service.tt'   => 'clod-worker.service',
        'clod.salvage.sh.tt'       => 'clod-salvage.sh',
        'clod.sudoers.tt'          => 'clod.sudoers',
        'clod.share.sh.tt'         => 'clod-share.sh',
        'clod.claude.sh.tt'        => 'clod-claude.sh',
        'clod.deps.sh.tt'          => 'clod-deps.sh',
        'clod.agent-token.tt'      => 'clod-agent.token',
        'clod.install-packages.tt' => 'clod-install-packages',
    );
}

sub tests {
    return qw{clod.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

The host of C<repo_url>, which is GitHub for the default.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;
    return Provisioner::Utils::host_of( $opts{repo_url} // $DEFAULT_REPO ) || ();
}

1;
