package Provisioner::Recipe::mail;

#ABSTRACT: Set up and configure a full mailserver stack.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::mail

=head2 SYNOPSIS

    somedomain:
        mail:
            relay:
                host: "mail.somerelay.net"
                port: 25025
                to:
                    - "somesite.net"
            names:
                me:
                    gecos: "Me"
                    password: "@Test_123!"
                you:
                    gecos: "You"
                    password: "@Test_123!"
                    mailboxes:
                        - "INBOX.foo"
                        - "INBOX.bar"
            mail_aliases:
                - Me: you
                - You: me

=head2 DESCRIPTION

Setup and configure a mailserver (postfix MUA, dovecot LDA, amavis + opendmarc + opendkim)

Supports SMTP relaying to other hosts, and in general chooses sane defaults.
Optionally restrict what hosts you use the relay for sending to.

Sets up the virtual users you specify with the provided passwords, and mailboxes.

If you have existing mailboxes, they ought be in $data_dir/mailnames/
If a sieve script in the $data_dir/mailnames/$USER/$USER.sieve exists, we will run sievec on it, and link it as .dovecot.sieve.

TODO: gather this data from something secure, such as keepass or vault.

=cut

use UUID qw{uuid};
use MIME::Base64 qw{encode_base64};
use Crypt::Digest::SHA512 qw{sha512};

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{postfix postfix-pcre dovecot-imapd dovecot-pop3d dovecot-antispam dovecot-sieve dovecot-lmtpd postgrey opendmarc opendkim spamassassin clamav amavisd-new rpm2cpio 7zip bzip2 lrzip lzop unrar-free};
    }
    die "Unsupported packager";
}

sub dep_conflicts {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{sendmail};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        properties => {
            names => {
                type                 => 'object',
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{password gecos}],
                    properties => {
                        password => { type => 'string' },
                        gecos    => { type => 'string' },
                    },
                },
            },
            mail_aliases => {
                type  => 'array',
                default => [],
                items => {
                    type       => 'object',
                    required   => [qw{from to}],
                    properties => {
                        from => { type => 'string' },
                        to   => { type => 'string' },
                    },
                },
            },
            relay  => {
                type       => "object",
                default => {},
                parameters => {
                    host => { type => "string" },
                    port => { type => "integer", minimum => 0 },
                },
            },
            # Built for us by bin/new_config from the ipmap
            full_aliases => {
                type  => 'array',
                default => [],
                items => { type => 'string' },
            },
            ipv6 => { type => 'boolean', default => 1 },
        },
    );
}

sub template_files {
    my ( $self, @recipes ) = @_;

    return (
        'mail.aliases.tt'                => 'aliases',
        'mail.header_checks.tt'          => 'header_checks',
        'mail.virtual_maps.tt'           => 'virtual_maps',
        'mail.virtual_aliases.tt'        => 'virtual_aliases',
        'mail.transport_maps.tt'         => 'transport_maps',
        'mail.sdd_relay_maps.tt'         => 'sdd_relay_maps',
        'mail.recipient_access_pcre.tt'  => 'recipient_access_pcre',
        'mail.dovecot.tt'                => 'dovecot.conf',
        'mail.dovecot.domain.tt'         => 'dovecot.domain.conf',
        'mail.passwd.tt'                 => 'mailpasswd',
        'mail.opendkim.tt'               => 'opendkim.conf',
        'mail.opendkim-trustedhosts.tt'  => 'TrustedHosts',
        'mail.opendkim-signingtable.tt'  => 'SigningTable',
        'mail.opendkim-keytable.tt'      => 'KeyTable',
        'mail.opendkim-internalhosts.tt' => 'InternalHosts',
        'mail.opendmarc.tt'              => 'opendmarc.conf',
        'mail.opendmarc-ignorehosts.tt'  => 'ignore.hosts',
        'mail.postfix.master.tt'         => 'master.cf',
        'mail.amavis.tt'                 => '50-user',
        'mail.autodiscover.tt'           => 'autodiscover.xml',
        'mail.autodiscover_vhost.tt'     => 'autodiscover_vhost',
        'mail.cron.tt'                   => 'mailcron',
    );
}

sub formatters {
    my ($class) = shift;
    return (
        salted_sha_512 => Text::Xslate::html_builder(
            sub {
                my $pw   = shift;
                my $salt = uuid();

                # https://doc.dovecot.org/2.3/configuration_manual/authentication/password_schemes/#salting
                my $raw = encode_base64( sha512("$pw$salt") . $salt );
                $raw =~ s/\n//g;
                return "{SSHA512}$raw";
            }
        ),
    );
}

sub datadirs {
    return ('.mail');
}

sub remote_files {
    my ( $class, $install_dir, $domain ) = @_;
    return (
        '/mail/keys'    => '.mail/keys',
        "/mail/$domain" => 'mailnames',
    );
}

sub tests {
    return qw{mail.tt};
}

1;
