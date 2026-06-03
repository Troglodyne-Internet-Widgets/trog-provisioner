package Trog::Provisioner::Web;

use strict;
use warnings;

use File::Slurper ();
use YAML::XS      ();

=head1 DESCRIPTION

Business logic for the provisioner web UI.
Separated from Routes.pm so it can be unit-tested without loading TPSGI.

=cut

=head2 get_recipes($provisioners_repo)

Return a sorted list of provisionable domain names from recipes.yaml
(and recipes.d/*.yaml) in the given provisioners repo.

=cut

sub get_recipes {
    my ($provisioners_repo) = @_;

    my $recipes_file = "$provisioners_repo/recipes.yaml";
    die "recipes.yaml not found at $recipes_file" unless -f $recipes_file;

    my $data = YAML::XS::Load( File::Slurper::read_text($recipes_file) );

    my %domains;
    for my $key ( keys %$data ) {
        next if $key eq '_base' || $key eq '_shared';
        $domains{$key} = 1;
    }

    # Merge in recipes.d/*.yaml if present
    my $recipes_d = "$provisioners_repo/recipes.d";
    if ( -d $recipes_d ) {
        opendir( my $dh, $recipes_d ) or die "Cannot opendir $recipes_d: $!";
        for my $f ( grep { /\.yaml$/ } readdir($dh) ) {
            local $@;
            my $extra = eval {
                YAML::XS::Load( File::Slurper::read_text("$recipes_d/$f") );
            };
            next if $@ || !ref $extra;
            for my $key ( keys %$extra ) {
                next if $key eq '_base' || $key eq '_shared';
                $domains{$key} = 1;
            }
        }
        closedir $dh;
    }

    return sort keys %domains;
}

=head2 new_config_cmd($domain, $provisioners_repo)

Return the shell command list to run bin/new_config for the domain.

=cut

sub new_config_cmd {
    my ( $domain, $provisioners_repo ) = @_;
    return ( "$provisioners_repo/bin/new_config", '--skip_ssh', $domain );
}

=head2 provision_cmd($domain, $domain_dir)

Return the shell command list to run bin/provision.
Looks for bin/provision relative to the module's FindBin location (repo root).

=cut

sub provision_cmd {
    my ( $domain, $domain_dir ) = @_;
    use FindBin ();
    my $bin = "$FindBin::Bin/../bin/provision";
    return ( $bin, '--domaindir', $domain_dir, $domain );
}

=head2 stream_provision($domain, $provisioners_repo, $domain_dir, $out_fh)

Run new_config then bin/provision for the given domain, writing all output
line-by-line to $out_fh.  Returns the exit code of the last command (0 = OK).

=cut

sub stream_provision {
    my ( $domain, $provisioners_repo, $domain_dir, $out_fh ) = @_;

    my @new_config = new_config_cmd( $domain, $provisioners_repo );
    my @provision  = provision_cmd( $domain, $domain_dir );

    for my $cmd ( \@new_config, \@provision ) {
        my $label = $cmd->[-1] eq $domain ? 'bin/provision' : 'bin/new_config';
        print $out_fh "=== Running $label ===\n";

        my $cmdstr = join( ' ', map { _shell_quote($_) } @$cmd );
        open( my $pipe, '-|', $cmdstr . ' 2>&1' )
            or do {
            print $out_fh "ERROR: could not exec $cmdstr: $!\n";
            return 1;
            };

        while ( defined( my $line = <$pipe> ) ) {
            print $out_fh $line;
        }
        close $pipe;
        my $rc = $? >> 8;
        if ($rc) {
            print $out_fh "=== $label exited with code $rc ===\n";
            return $rc;
        }
    }

    print $out_fh "=== Provisioning complete ===\n";
    return 0;
}

sub _shell_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

=head2 index_html(\@recipes)

Generate the index page HTML with a provisioning form.

=cut

sub index_html {
    my ($recipes) = @_;

    my $options = join(
        "\n",
        map { my $r = _html_escape($_); "<option value=\"$r\">$r</option>" }
            @$recipes
    );

    return <<"HTML";
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Provisioner</title></head>
<body>
<h1>Provision a Domain</h1>
<form method="POST" action="/provision">
  <label for="domain">Domain:</label>
  <select id="domain" name="domain">
$options
  </select>
  <br><br>
  <input type="submit" value="Provision">
</form>
</body>
</html>
HTML
}

sub _html_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

1;
