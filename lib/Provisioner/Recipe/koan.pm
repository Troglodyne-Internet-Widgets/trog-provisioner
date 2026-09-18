package Provisioner::Recipe::koan;

#ABSTRACT: Install and run the Koan autonomous coding bot.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

# One copy for args and fetch_hosts, so that two copies do not drift apart.
our $DEFAULT_REPO = 'https://github.com/troglodyne/koan.git';

use Crypt::PRNG();
use File::Temp();
use File::Slurper();

=head1 Provisioner::Recipe::koan

=head2 SYNOPSIS

    somedomain:
        koan:
            user: koan
            koan_email: "koan@somedomain.test"

            # Where to fetch koan from.  The default is the troglodyne fork,
            # which has the Megolm/Olm E2EE rewrite.  Change it only if
            # upstream sukria/koan has that support.
            repo_url:    "https://github.com/troglodyne/koan.git"
            repo_branch: "add_matrix_e2ee"

            # The CLI that drives the agent (claude|codex|copilot|local).
            cli_provider: "claude"

            # Required when cli_provider=claude.  This is the long-lived
            # OAuth token that `claude setup-token` makes on a workstation.
            claude_oauth_token: "sk-ant-..."

            # The GitHub identity of the bot.  The PAT needs the repo and
            # notifications scopes.
            github_user:  "yourname-koan"
            github_token: "ghp_..."

            # Give the bot an ssh identity for git push and commit signing.
            # See guest_secrets below.  Register the public key that the
            # build prints on the GitHub account of the bot.  Add it as an
            # "Authentication key" for push and as a "Signing key", so that
            # signed commits show as Verified.
            github_ssh_identity: 1

            # The name for @mentions.  The default is github_user.
            github_nickname: "yourname-koan"

            # Personal accounts that can drive the bot with an @mention.
            github_authorized_users:
                - "yourname"

            # Messaging.  Pick exactly one of telegram, slack or matrix.
            messaging_provider: "telegram"
            telegram_token:   "123456789:ABC-..."
            telegram_chat_id: "987654321"

            # slack_bot_token: "xoxb-..."
            # slack_app_token: "xapp-..."
            # slack_channel_id: "C01234ABCD"

            # matrix_homeserver: "https://matrix.org"
            # matrix_user_id:    "@koan:matrix.org"
            # matrix_room_id:    "!abcdef:matrix.org"
            # matrix_e2ee:       1                   # the default, 0 for plaintext
            # For the credentials, give EITHER:
            #   matrix_access_token: "syt_..."       # pre-minted token
            #   matrix_device_id:    "BRAND_NEW"     # required when e2ee=1
            # OR, but not both:
            #   matrix_password:     "hunter2"       # bootstrap mints a new device
            # matrix_pickle_key: "<64-hex>"          # optional, see DESCRIPTION

            # Behavior settings.  All are optional.
            max_runs_per_day: 10
            interval_seconds: 60

            # Optional SMTP for session digest emails.
            # smtp_host:     "smtp.example.test"
            # smtp_port:     587
            # smtp_user:     "koan@example.test"
            # smtp_password: "..."
            # email_to:      "you@example.test"

            # The projects that the bot works on.  Each entry needs an
            # absolute `path` on the guest and a `github_url`, either
            # "owner/repo" or a full https:// URL.  The first provision
            # clones the repo to that path with `gh repo clone` and the
            # github_token of the bot.  Later provisions skip the clone
            # when .git/ is already there.
            projects:
                myapp:
                    path: "/opt/projects/myapp"
                    github_url: "myorg/myapp"
                api:
                    path: "/opt/projects/api"
                    github_url: "https://github.com/myorg/api.git"
                    cli_provider: "copilot"

=head2 DESCRIPTION

Installs and runs the Koan autonomous coding bot
(L<https://github.com/troglodyne/koan>).  This is our fork, with Matrix
support that is end-to-end encrypted with Megolm/Olm.  Upstream is at
L<https://github.com/sukria/koan>.  The bot runs as two systemd services,
C<koan.service> and C<koan-awake.service>, as the service user of the recipe.

When C<messaging_provider> is C<matrix>, E2EE is on by default and the bot
needs a new device.  The recipe gets one in one of two ways:

=over 1

=item * B<Pre-mint>: you make a new device in Element.  You give the
        C<matrix_access_token> and C<matrix_device_id> of that device in
        recipes.yaml.

=item * B<Bootstrap>: you give only C<matrix_password>.  On the first
        provision the recipe runs C<python -m app.matrix_login> as the
        service user.  This mints a new device and writes
        C<instance/matrix/credentials.env> in a directory with mode 0700.
        A later provision skips the bootstrap while that file exists.

=back

The layout on the guest:

    [install_dir]/[domain]/           $HOME of the service user (.ssh, .gitconfig, .venv)
    [install_dir]/[domain]/koan/      repo checkout (KOAN_ROOT)
    [install_dir]/[domain]/koan/koan/ python package (PYTHONPATH, WorkingDir)
    [install_dir]/[domain]/koan/.env  secrets
    [install_dir]/[domain]/koan/instance/  bot state (kept)
    [install_dir]/[domain]/koan/logs/      service log files (kept)
    [install_dir]/[domain]/.venv/     python virtualenv (outside the repo, so
                                      that git reset --hard does not remove it)

KOAN_ROOT is a subdirectory of the home directory, not the home directory
itself.  The C<service_user> target makes C<install_dir/domain/> before the
recipe runs, and C<git clone> does not clone into a directory that is not empty.

The Olm/Megolm store is at C<koan/instance/matrix-store/>.  C<remote_files>
keeps it across builds with the rest of C<koan/instance/>.  Without the store,
the bot cannot decrypt past room sessions, so do not C<rm -rf> the data
directory.

The C<matrix_pickle_key> encrypts that store.  If you do not set one,
C<enrich> makes a new one each time it runs.  Set it to keep the key the same
from one build to the next.

The recipe does these steps:

=over 1

=item * It installs the system packages (git, python venv, nodejs and C<npm>, gh).

=item * It clones koan into C<install_dir/domain/koan>.

=item * It renders C<.env>, C<instance/config.yaml> and C<projects.yaml>.

=item * It builds the python virtualenv.

=item * It installs C<@anthropic-ai/claude-code> globally when
        cli_provider=claude.

=item * It writes the systemd unit files and queues the services to start.

=back

The secrets (the telegram, slack and matrix tokens, the github PAT, the claude
OAuth token and the SMTP password) are in the rendered C<.env> file.  That file
is installed 0640 root:I<user>.  The makefile fragment also holds the github
PAT, and the matrix password and pickle key for the bootstrap.

C<remote_files> keeps the C<instance/> tree across provisions.  So the memory,
journal and missions of the bot stay after a rebuild.

=head3 Host CPU requirements

When C<cli_provider=claude>, the recipe installs the C<@anthropic-ai/claude-code>
CLI on the guest.  Its bundled v8 snapshot probes cpuid at startup.  It stops
with C<SIGILL> on a guest whose CPU model has no AVX, and the qemu default
C<qemu64> is one such model.  The C<vm> recipe sets C<cpu_mode> to
C<host-passthrough> by default, which shows the real CPU to the guest.  If you
change C<cpu_mode> for a koan host, pick a model that has AVX.  Otherwise
C<claude> crashes the first time it runs.

C<deps> is in L<Provisioner::Recipe::Ubuntu::koan>.

=cut

sub required_recipes {
    return ( claude => sub { () } );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  This recipe installs two units for the whole machine,
F</etc/systemd/system/koan.service> and F<koan-awake.service>.  Both name the
checkout, the virtualenv and the F<.env> of this domain.  A second domain does
not get its own koan.  It rewrites those units to point at itself.

=cut

sub is_multi_tenant { return 0 }

sub args {
    return (
        type       => 'object',
        required   => [qw{user koan_email github_user github_token}],
        properties => {
            koan_email => { type => 'email' },
            repo_url   => { type => 'string', default => $DEFAULT_REPO },

            # The troglodyne fork has the Megolm/Olm E2EE matrix provider and the
            # `app.matrix_login` bootstrap.  Upstream koan (sukria/koan) excludes E2EE.
            # HTTPS, not SSH, because a new VM has no key registered with GitHub.
            repo_branch             => { type => 'string', default => 'add_matrix_e2ee' },
            messaging_provider      => { type => 'string', enum    => [qw{telegram slack matrix}], default => 'telegram' },
            telegram_token          => { type => 'string' },
            telegram_chat_id        => { type => 'string' },
            slack_bot_token         => { type => 'string' },
            slack_app_token         => { type => 'string' },
            slack_channel_id        => { type => 'string' },
            matrix_homeserver       => { type => 'string' },
            matrix_user_id          => { type => 'string' },
            matrix_room_id          => { type => 'string' },
            matrix_e2ee             => { type => 'boolean', default => 1 },
            matrix_access_token     => { type => 'string' },
            matrix_device_id        => { type => 'string' },
            matrix_password         => { type => 'string' },
            matrix_pickle_key       => { type => 'string' },
            cli_provider            => { type => 'string', enum => [qw{claude codex copilot local}], default => 'claude' },
            claude_oauth_token      => { type => 'string' },
            github_user             => { type => 'string' },
            github_token            => { type => 'string' },
            github_nickname         => { type => 'string' },
            github_authorized_users => { type => 'array',   items   => { type => 'string' }, default => [] },
            github_ssh_identity     => { type => 'boolean', default => 0, description => 'Give the bot an ssh identity for git push and commit signing.  The key itself lives in the secret store and is placed on the guest by bin/provision; it is never written into the payload.  Register the pubkey the first build prints under the bot GitHub account, as an Authentication key and a Signing key.' },
            max_runs_per_day        => { type => 'integer', default => 10 },
            interval_seconds        => { type => 'integer', default => 60 },
            start_on_pause          => { type => 'integer', default => 1 },
            focus                   => { type => 'integer', default => 0 },
            projects                => {
                type                 => 'object',
                default              => {},
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{path}],
                    properties => {
                        path         => { type => 'string', pattern => '^/' },
                        cli_provider => { type => 'string', enum    => [qw{claude codex copilot local}], default => 'claude' },
                        github_url   => { type => 'string' },
                        base_branch  => { type => 'string', default => 'master' },
                    }
                },
            },

            # TODO: Put these in one object, so that the schema can require them together.
            smtp_host     => { type => 'string' },
            smtp_port     => { type => 'integer' },
            smtp_user     => { type => 'string' },
            smtp_password => { type => 'string' },
            email_to      => { type => 'string' },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Sets C<github_nickname> to C<github_user> when it is not given.  For matrix,
it turns E2EE on by default and mints C<matrix_pickle_key> when E2EE is on and
no key was given.

Dies when the messaging provider has no credentials, when the matrix
credentials are not exactly one of a token or a password, and when a token has
no C<matrix_device_id> under E2EE.  Dies when C<cli_provider> is C<claude> and
there is no C<claude_oauth_token>.  Dies when only some of the SMTP settings
are given.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{github_nickname} //= $opts{github_user};

    if ( $opts{messaging_provider} eq 'telegram' ) {
        die "Must set telegram_token in [koan] section"   unless $opts{telegram_token};
        die "Must set telegram_chat_id in [koan] section" unless defined $opts{telegram_chat_id};
    }
    elsif ( $opts{messaging_provider} eq 'slack' ) {
        die "Must set slack_bot_token in [koan] section"  unless $opts{slack_bot_token};
        die "Must set slack_app_token in [koan] section"  unless $opts{slack_app_token};
        die "Must set slack_channel_id in [koan] section" unless $opts{slack_channel_id};
    }
    elsif ( $opts{messaging_provider} eq 'matrix' ) {
        die "Must set matrix_homeserver in [koan] section" unless $opts{matrix_homeserver};
        die "Must set matrix_user_id in [koan] section"    unless $opts{matrix_user_id};
        die "Must set matrix_room_id in [koan] section"    unless $opts{matrix_room_id};

        # Pre-mint or bootstrap, see DESCRIPTION.
        my $have_token = !!$opts{matrix_access_token};
        my $have_pw    = !!$opts{matrix_password};
        die "matrix needs exactly one of: matrix_access_token (+matrix_device_id), or matrix_password"
          unless $have_token xor $have_pw;
        if ($have_token) {
            die "matrix_device_id is required when matrix_access_token is set"
              if $opts{matrix_e2ee} && !$opts{matrix_device_id};
        }

        if ( $opts{matrix_e2ee} && !$opts{matrix_pickle_key} ) {
            $opts{matrix_pickle_key} = join '',
              map { ( 0 .. 9, 'a' .. 'f' )[ Crypt::PRNG::rand(16) ] } 1 .. 64;
        }
    }

    die "Must set claude_oauth_token in [koan] section when cli_provider=claude"
      if $opts{cli_provider} eq 'claude' && !$opts{claude_oauth_token};

    if ( $opts{smtp_host} || $opts{smtp_user} || $opts{email_to} ) {
        die "smtp_host, smtp_user, smtp_password and email_to must all be set together"
          unless $opts{smtp_host}
          && $opts{smtp_user}
          && $opts{smtp_password}
          && $opts{email_to};
        $opts{smtp_port} //= 587;
    }

    return %opts;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

Returns the ssh identity of the bot when C<github_ssh_identity> is true, and
an empty list when it is false.

The first build makes the key and keeps it in the secret store.  Every later
provision takes it from the store, and the key never goes in the payload.
C<remote_files> does not name F<.ssh>, so the key is only on the guest and in
the store.

To keep a key that GitHub already knows, put it in the store with
C<bin/add_secret> before the first build.  If you do not, that build mints a
new key and GitHub does not know it:

    bin/add_secret --group koan --title <domain>-github-ssh -- "$(cat old_key)"

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain, %opts ) = @_;

    return () unless $opts{github_ssh_identity};

    return (
        "$install_dir/$domain/.ssh/id_koan" => {
            ref => "secret:koan/$domain-github-ssh/password",

            # Ed25519 because the key fits in a password field, and no
            # passphrase because the bot runs unattended.
            generate => sub {
                my $dir  = File::Temp::tempdir( CLEANUP => 1 );
                my $path = "$dir/id_koan";
                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => 256, 'koan' );

                # Remove the trailing newline.  bin/provision adds one, and
                # ssh-keygen refuses a key that ends with a blank line.
                my $key = File::Slurper::read_binary($path);
                $key =~ s/\n\z//;
                return $key;
            },

            # Owned by root until the fragment gives it to the service user,
            # because the file is placed before the makefile makes the account.
            mode => '0600',
        },
    );
}

=head2 @files = $recipe->template_files()

Returns pairs of a template and the file that it renders to: the env file, the
behavior configuration, the project list, the two systemd units, the ufw
profile and the gh auth state.

=cut

sub template_files {
    return (
        'koan.env.tt'           => 'koan.env',
        'koan.config.yaml.tt'   => 'koan.config.yaml',
        'koan.projects.yaml.tt' => 'koan.projects.yaml',
        'koan.service.tt'       => 'koan.service',
        'koan-awake.service.tt' => 'koan-awake.service',

        # The ufw profile that opens the matrix federation port outbound.
        # It is always rendered, and the fragment installs it only for matrix.
        'koan.ufw.conf.tt' => 'koan_ufw.conf',

        # The gh auth state, so that the bot can run `gh` without `gh auth login`.
        'koan-gh-hosts.yml.tt' => 'koan-gh-hosts.yml',
    );
}

=head2 @dirs = $recipe->datadirs()

Returns C<koan>, so that C<remote_files> has a data directory to copy into on
the first provision.

=cut

sub datadirs {
    return qw{koan};
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

Returns what to copy back from the guest into the data directory, so that the
next build keeps it: C<instance/>, C<logs/>, C<workspace/>, C<projects.yaml>
and the Claude Code state in F<.claude.json>.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/koan/instance/"     => 'koan/instance/',
        "$install_dir/$domain/koan/logs/"         => 'koan/logs/',
        "$install_dir/$domain/koan/workspace/"    => 'koan/workspace/',
        "$install_dir/$domain/koan/projects.yaml" => 'koan/projects.yaml',

        # Claude writes its account and session state here on first use.
        # Without it, the next build must log in again by hand.
        "$install_dir/$domain/.claude.json" => '.claude.json',
    );
}

sub tests {
    return qw{koan.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

Returns the host of C<repo_url>, which is GitHub for the default repo.  When
the class is asked without a configuration, it returns the host of the default.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;
    return Provisioner::Utils::host_of( $opts{repo_url} // $DEFAULT_REPO ) || ();
}

1;
