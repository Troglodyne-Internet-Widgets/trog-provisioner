package Provisioner::MailAccount;

#ABSTRACT: The mail accounts of a guest: the passwd-file line, and the tools that change it while the guest runs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Slurper();
use List::Util qw{any};
use YAML::XS();

use Provisioner::Cookbook();
use Provisioner::Utils();
use Trog::Config();
use Trog::Credentials();
use Trog::Hypervisors();
use Trog::Secrets();

=head1 NAME

Provisioner::MailAccount - the mail accounts of a guest

=head1 SYNOPSIS

    my $line = Provisioner::MailAccount::passwd_line(
        domain => 'example.test', name => 'someone', gecos => 'Some One', password => 'x',
    );

    Provisioner::MailAccount::add( domain => $d, name => $n, guest => $guest, ... );

=head1 DESCRIPTION

The C<mail> recipe makes its accounts from C<mail.names> and renders each one
into F</mail/$domain/passwd>, the passwd-file that dovecot reads.  This module
is the one place that knows what a line of that file looks like.  The template
of the recipe and C<bin/add_mail_user>, C<bin/reset_mail_password> and
C<bin/remove_mail_user> all call C<passwd_line>.  So the tools write the same
line that a build would write.

The tools change three things, and keep them the same: the secret store, the
configuration of the domain, and the passwd-file on the running guest.  A
rebuild then makes the account that the tool made.

=head1 SUBROUTINES

=cut

# Where the mail stores of a guest are.  A test points it at a scratch directory.
our $MAIL_ROOT = '/mail';

# What the template puts in the uid and the gid fields.  The build replaces it
# with the uid of dovecot on the guest, which only the guest knows.
our $UID_PLACEHOLDER = '%REPLACEME%';

# Returns $str quoted for a POSIX shell.
my sub shq ($str) {
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

=head2 $address = address($domain, $name)

C<$name@$domain>.  It is the key of the line in the passwd-file, and the user
name that dovecot and C<doveadm> know.

=cut

sub address ( $domain, $name ) {
    return "$name\@$domain";
}

=head2 $ref = secret_ref($domain, $name)

The reference of the password of the account in the secret store:
C<secret:mail/$domain-$name/password>.

=cut

sub secret_ref ( $domain, $name ) {
    return "secret:mail/$domain-$name/password";
}

=head2 check_name($name)

Returns 1 for a name that the passwd-file, a path and a shell command can all
hold: letters, digits, dots, plus signs, hyphens and underscores.  Dies for any
other.  The recipe asks this in C<enrich>, because the template engine only warns
when a function dies, and then renders nothing.  An account would vanish from
the passwd-file and the build would go on.

=cut

sub check_name ($name) {
    die "The name of a mail account is letters, digits, dots, plus signs, hyphens and underscores, not '$name'.\n" unless $name =~ m/\A[\w.+-]+\z/;
    return 1;
}

=head2 passwd_line(%args)

The line of the passwd-file for one account.  Takes C<domain>, C<name>,
C<gecos>, and either C<password>, which it hashes with
L<Provisioner::Utils/dovecot_password_hash>, or C<hash>.  C<uid> defaults to the
placeholder that the build replaces with the uid of dovecot.  Dies on a name, a
domain or a gecos that would put a colon or a line break into the file, because
the passwd-file has no way to quote one.

=cut

sub passwd_line (%args) {
    my ( $domain, $name, $gecos ) = @args{qw{domain name gecos}};

    my $incomplete = length( $name // q{} ) == 0 || length( $domain // q{} ) == 0 || !( defined $args{password} || defined $args{hash} );
    die "A mail account needs a name, a domain and a password or hash.\n" if $incomplete;
    check_name($name);
    die "The domain of a mail account is letters, digits, dots and hyphens, not '$domain'.\n" unless $domain =~ m/\A[\w.-]+\z/;
    $gecos //= q{};
    die "The gecos of $name\@$domain holds a colon or a line break, which the passwd-file cannot hold.\n" if $gecos =~ m/[:\n\r]/;

    my $hash = $args{hash} // Provisioner::Utils::dovecot_password_hash( $args{password} );
    die "The hash of $name\@$domain holds a colon or a line break.\n" if $hash =~ m/[:\n\r]/;

    my $uid = $args{uid} // $UID_PLACEHOLDER;
    return join( q{:}, address( $domain, $name ), $hash, $uid, $uid, $gecos, "/mail/$domain/$name", '/usr/sbin/noshell' );
}

# The lines of a passwd-file that are accounts, as [ address, line ].
my sub accounts_of ($text) {
    return map { m/\A([^:\s][^:]*):/ ? [ $1, $_ ] : () } grep { !m/\A\s*(?:\#|\z)/ } split( m/\n/, $text // q{} );
}

=head2 @addresses = addresses_in($text)

The address of each account in the passwd-file text C<$text>, in file order.

=cut

sub addresses_in ($text) {
    return map { $_->[0] } accounts_of($text);
}

=head2 $bool = has_address($text, $address)

True when C<$address> is the address of an account in the passwd-file text
C<$text>.

=cut

sub has_address ( $text, $address ) {
    return any { $_ eq $address } addresses_in($text);
}

=head2 $text = add_line($text, $line)

C<$text> with C<$line> at the end.  Dies if the address of the line is already
in C<$text>.

=cut

sub add_line ( $text, $line ) {
    my ($address) = $line =~ m/\A([^:]+):/ or die "Not a passwd-file line: $line\n";
    die "$address is already in the passwd-file.\n" if has_address( $text, $address );

    $text .= "\n" if length($text) > 0 && $text !~ m/\n\z/;
    return "$text$line\n";
}

=head2 $text = replace_hash($text, $address, $hash)

C<$text> with the hash of C<$address> replaced, and every other byte as it was.
Dies if the address is not in C<$text>, or is there more than once.

=cut

sub replace_hash ( $text, $address, $hash ) {
    die "The hash holds a colon or a line break.\n" if $hash =~ m/[:\n\r]/;

    my @hits = grep { $_->[0] eq $address } accounts_of($text);
    die "$address is not in the passwd-file.\n" unless @hits;
    die "$address is in the passwd-file " . scalar(@hits) . " times.\n" if @hits > 1;

    my $old   = $hits[0][1];
    my @field = split( m/:/, $old, -1 );
    $field[1] = $hash;
    my $new = join( q{:}, @field );

    # Anchored to the whole line, so a line that holds this one as its tail is
    # not the one that changes.
    $text =~ s/^\Q$old\E(?=\n|\z)/$new/m;
    return $text;
}

=head2 $text = remove_line($text, $address)

C<$text> without the line of C<$address>.  Dies if it is not there.

=cut

sub remove_line ( $text, $address ) {
    my @hits = grep { $_->[0] eq $address } accounts_of($text);
    die "$address is not in the passwd-file.\n" unless @hits;

    my $old = $hits[0][1];
    $text =~ s/^\Q$old\E\n?//m;
    return $text;
}

=head2 $accounts = configured_accounts($domain)

The C<mail.names> of C<$domain>, as the configuration says them, with the
C<secret:> references not resolved.  An empty hash reference when there are
none.

=cut

sub configured_accounts ($domain) {
    return Provisioner::Cookbook->domain_config($domain)->{mail}{names} // {};
}

# The own file of the domain, which the tools write.  See record_setting in
# Provisioner::Cookbook.
my sub own_names ($domain) {
    my $path = Trog::Config->path("recipes.d/$domain.yaml");

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return {} unless -f $path;
    return YAML::XS::Load( File::Slurper::read_binary($path) )->{$domain}{mail}{names} // {};
}

=head2 add_to_configuration($domain, $name, %account)

Adds the account to C<mail.names> in F<recipes.d/$domain.yaml>, and leaves the
rest of that file as it was.  C<%account> is C<password>, C<gecos> and
C<mailboxes>.  Dies if F<recipes.yaml> sets C<mail.names> for the domain,
because a value there wins over this file, so the account would not take
effect.

=cut

sub add_to_configuration ( $domain, $name, %account ) {
    my $names = own_names($domain);
    $names->{$name} = {%account};
    return Provisioner::Cookbook->record_setting( $domain, 'mail', 'names', $names );
}

=head2 remove_from_configuration($domain, $name)

Takes the account out of F<recipes.d/$domain.yaml>.  Dies for an account that is
not in that file, for example one that F<recipes.yaml> holds, and says which
file to edit.

=cut

sub remove_from_configuration ( $domain, $name ) {
    my $names = own_names($domain);
    die "$name is not in recipes.d/$domain.yaml, so this cannot take it out.  If recipes.yaml holds it, take it out there.\n" unless exists $names->{$name};

    delete $names->{$name};
    return Provisioner::Cookbook->record_setting( $domain, 'mail', 'names', $names );
}

# Runs $script as root on the guest, and returns the exit code.
my sub root ( $guest, $script ) {
    return $guest->run_cmd( qw{sudo -n sh -c}, $script );
}

# Runs $script as root on the guest, and returns what it printed.
my sub root_out ( $guest, $script ) {
    return $guest->capture_cmd( 'sudo -n sh -c ' . shq($script) ) // q{};
}

=head2 $text = read_passwd($guest, $domain)

The passwd-file of C<$domain> on the guest, or undef where the file is not there.

=cut

sub read_passwd ( $guest, $domain ) {
    my $path = "$MAIL_ROOT/$domain/passwd";
    return if root( $guest, 'test -f ' . shq($path) );
    return root_out( $guest, 'cat ' . shq($path) );
}

=head2 write_passwd($guest, $domain, $text)

Replaces the passwd-file of C<$domain> on the guest with C<$text>.  It writes a
temporary file in the same directory, gives it the owner and the mode of the
file it replaces, and renames it.  The rename is one step, so dovecot reads the
old file or the new one and never half of either.  Dies, and removes the
temporary file, if any step fails.

=cut

sub write_passwd ( $guest, $domain, $text ) {
    my $dir  = "$MAIL_ROOT/$domain";
    my $path = "$dir/passwd";

    my $tmp = root_out( $guest, 'mktemp ' . shq("$dir/.passwd.XXXXXX") );
    chomp $tmp;
    die "Could not make a temporary file in $dir on the guest.\n" unless $tmp =~ m{\A\Q$dir\E/[.]passwd[.]\w+\z};

    my $moved = eval {
        $guest->write_text( $tmp, $text, sudo => 1, mode => '0600' ) or die "Could not write $tmp on the guest.\n";
        root( $guest, 'chown --reference=' . shq($path) . q{ } . shq($tmp) . ' && chmod --reference=' . shq($path) . q{ } . shq($tmp) . ' && mv -f ' . shq($tmp) . q{ } . shq($path) ) == 0;
    };
    my $why = $@;
    unless ($moved) {
        root( $guest, 'rm -f ' . shq($tmp) );
        die $why || "Could not move $tmp over $path on the guest.\n";
    }

    return 1;
}

=head2 $uid = dovecot_uid($guest)

The uid of the C<dovecot> account on the guest.  The template gives the same
number as the uid and as the gid.

=cut

sub dovecot_uid ($guest) {
    my $uid = $guest->capture_cmd('id -u dovecot') // q{};
    chomp $uid;
    die "Could not read the uid of dovecot on the guest.\n" unless $uid =~ m/\A\d+\z/;
    return $uid;
}

=head2 make_mailboxes($guest, $address, @mailboxes)

Makes each mailbox with C<doveadm mailbox create>, and skips one that is there,
as the template does.

=cut

sub make_mailboxes ( $guest, $address, @mailboxes ) {
    foreach my $box (@mailboxes) {
        my ( $u, $b ) = ( shq($address), shq($box) );
        root( $guest, "doveadm mailbox status -u $u messages $b >/dev/null 2>&1 || doveadm mailbox create -u $u $b" ) == 0
          or die "doveadm could not make the mailbox $box for $address.\n";
    }
    return 1;
}

=head2 $bool = kick($guest, $address)

Ends the open sessions of C<$address> with C<doveadm kick>.  True when it
exited 0.  It exits non-zero for an account with no session, which is not a
failure of anything.

=cut

sub kick ( $guest, $address ) {
    return root( $guest, 'doveadm kick ' . shq($address) ) == 0;
}

=head2 $password = ask_password($address, %opts)

The password of an account.  With C<stdin>, one line of standard input, which
follows the credentials block that C<--credentials> reads.  Otherwise it asks at
the terminal with no echo, two times, through L<Trog::Credentials/typed_twice>.
Dies on an empty password, because an empty one lets nobody in or everybody.

=cut

sub ask_password ( $address, %opts ) {
    my $password;
    if ( $opts{stdin} ) {
        $password = <STDIN>;    ## no critic (InputOutput::ProhibitExplicitStdin) -- the password is the line after the credentials block
        chomp $password if defined $password;
    }
    else {
        $password = Trog::Credentials->typed_twice( "Password of $address:", $address );
    }

    die "No password was given for $address.\n" if length( $password // q{} ) == 0;
    return $password;
}

# The guest of the domain, or a sentence saying why there is none.
my sub guest_for ( $domain, %opts ) {
    return $opts{guest} if $opts{guest};

    return Trog::Hypervisors->guest_of($domain) // die "No hypervisor runs $domain, so there is no guest to change.  Build it with bin/provision, and the accounts of the configuration come with it.\n";
}

=head2 add(%args)

Makes the account.  Takes C<domain>, C<name>, C<gecos>, C<mailboxes> (an array
reference), C<password>, C<secrets> (the path of the store), and C<guest>.
Refuses an account that is in the configuration or in the passwd-file of the
guest, before it changes anything.  Then it stores the password, adds the line
and the mailboxes on the guest, and adds the account to the configuration.
The configuration comes last, so that a failure on the guest leaves nothing
behind that a second run refuses.

=cut

sub add (%args) {
    my ( $domain, $name ) = @args{qw{domain name}};
    my $address = address( $domain, $name );
    my @boxes   = @{ $args{mailboxes} // [] };
    my $gecos   = $args{gecos} // $name;
    my $ref     = secret_ref( $domain, $name );

    die "$address is already in the configuration of $domain, under mail.names.\n" if exists configured_accounts($domain)->{$name};

    # Before the guest changes, because this is the last step and the only one
    # that can be refused for a reason that has nothing to do with the guest.
    Provisioner::Cookbook->check_settable( $domain, 'mail', 'names' );

    my $guest  = guest_for( $domain, %args );
    my $passwd = read_passwd( $guest, $domain ) // die "$MAIL_ROOT/$domain/passwd does not exist on the guest of $domain.  Is the mail recipe built there?\n";
    die "$address is already in $MAIL_ROOT/$domain/passwd on the guest.  Nothing was changed.\n" if has_address( $passwd, $address );

    # Built before anything is written, so that a name that the passwd-file
    # cannot hold stops the run with the guest and the store as they were.
    my $line = passwd_line(
        domain => $domain,
        name   => $name,
        gecos  => $gecos,
        uid    => dovecot_uid($guest),
        hash   => Provisioner::Utils::dovecot_password_hash( $args{password} ),
    );

    # overwrite: nothing refers to this reference while the account is in
    # neither the configuration nor the guest, so a value left by a run that
    # stopped is not worth refusing for.
    Trog::Secrets->put( $args{secrets}, Trog::Credentials->store_password(), ref => $ref, value => $args{password}, overwrite => 1 );

    write_passwd( $guest, $domain, add_line( $passwd, $line ) );
    make_mailboxes( $guest, $address, @boxes );

    add_to_configuration( $domain, $name, password => $ref, gecos => $gecos, ( @boxes ? ( mailboxes => \@boxes ) : () ) );
    return 1;
}

=head2 reset_password(%args)

Gives the account a new password.  Takes C<domain>, C<name>, C<password>,
C<secrets>, C<guest>, and C<kick>.  Refuses an account that is not in
C<mail.names>, or whose password the configuration does not keep as a
C<secret:> reference, because there is no entry to replace.  It replaces the
value in the store, as C<bin/add_secret --overwrite> does.  The reference in
the configuration does not change.  On the guest it replaces the hash of that
one line, through a temporary file and a rename.

=cut

sub reset_password (%args) {
    my ( $domain, $name ) = @args{qw{domain name}};
    my $address = address( $domain, $name );

    my $account = configured_accounts($domain)->{$name} // die "$address is not in mail.names of $domain, so there is no account to reset.\n";
    my $ref     = $account->{password}                  // q{};
    die "The password of $address is written into the configuration and is not a secret: reference, so there is no entry in the store to replace.\n" . "Put it in the store with bin/add_secret, and write the reference into mail.names.\n"
      unless $ref =~ m/\Asecret:/;

    my $hash = Provisioner::Utils::dovecot_password_hash( $args{password} );

    my $guest  = guest_for( $domain, %args );
    my $passwd = read_passwd( $guest, $domain ) // die "$MAIL_ROOT/$domain/passwd does not exist on the guest of $domain.\n";
    die "$address is not in $MAIL_ROOT/$domain/passwd on the guest.  Nothing was changed.\n" unless has_address( $passwd, $address );

    Trog::Secrets->put( $args{secrets}, Trog::Credentials->store_password(), ref => $ref, value => $args{password}, overwrite => 1 );
    write_passwd( $guest, $domain, replace_hash( $passwd, $address, $hash ) );

    return $args{kick} ? ( kick( $guest, $address ) ? 'kicked' : 'no session' ) : 'done';
}

=head2 remove(%args)

Takes the account away.  Takes C<domain>, C<name>, C<secrets>, C<guest> and
C<kick>.  Refuses an account that is in neither the configuration nor the
passwd-file.  It removes the account from the configuration, then its line from
the passwd-file, then its entry from the store.  The mailboxes stay on the
disk of the guest, because they hold mail, and a tool that deletes mail on a
typing error is worse than one that leaves it.

=cut

sub remove (%args) {
    my ( $domain, $name ) = @args{qw{domain name}};
    my $address = address( $domain, $name );

    my $account  = configured_accounts($domain)->{$name};
    my $guest    = guest_for( $domain, %args );
    my $passwd   = read_passwd( $guest, $domain ) // die "$MAIL_ROOT/$domain/passwd does not exist on the guest of $domain.\n";
    my $on_guest = has_address( $passwd, $address );

    die "$address is not in mail.names of $domain, and not in $MAIL_ROOT/$domain/passwd on the guest.  Nothing was changed.\n" unless $account || $on_guest;

    remove_from_configuration( $domain, $name )                       if $account;
    write_passwd( $guest, $domain, remove_line( $passwd, $address ) ) if $on_guest;

    my $ref = ( $account // {} )->{password} // q{};
    Trog::Secrets->forget( $args{secrets}, Trog::Credentials->store_password(), $ref ) if $ref =~ m/\Asecret:/;

    kick( $guest, $address ) if $args{kick};
    return 1;
}

1;
