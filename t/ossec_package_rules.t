#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/ossec_package_rules.t - scripts/ossec_package_rules puts the rule list of the
package into our ossec.conf, and refuses when there is none to take

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use Capture::Tiny qw{capture};

use FindBin;

my $script = "$FindBin::Bin/../scripts/ossec_package_rules";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $dir = tempdir( CLEANUP => 1 );

sub file {
    my ( $name, $text ) = @_;
    File::Slurper::Temp::write_text( "$dir/$name", $text );
    return "$dir/$name";
}

my $package = file( 'package.conf', <<'XML' );
<!-- OSSEC example config -->
<!-- <rules><include>commented_rules.xml</include></rules> -->
<ossec_config>
  <global>
    <email_to>bogus@test.test</email_to>
  </global>
  <rules>
    <include>rules_config.xml</include>
    <include>syslog_rules.xml</include>
    <!-- <include>disabled_rules.xml</include> -->
    <include>apparmor_rules.xml</include>
    <include>local_rules.xml</include>
  </rules>
</ossec_config>
XML

my $ours = file( 'ours.conf', <<'XML' );
<ossec_config>
  <global>
    <email_notification>no</email_notification>
  </global>
  <rules>
    <!-- From the package. -->
  </rules>
  <remote>
    <port>10514</port>
  </remote>
</ossec_config>
XML

subtest 'main' => sub {
    my ( $out, $err, $exit ) = capture { Trog::OssecPackageRules::main( $package, $ours ) };
    is( $exit, 0, 'it exits clean' ) or diag $err;

    my @includes = $out =~ m{<include>([^<]+)</include>}g;
    is_deeply( \@includes, [qw{rules_config.xml syslog_rules.xml apparmor_rules.xml local_rules.xml}], 'with the rule files of the package, in its order, and none that it comments out' );
    like( $out, qr{<email_notification>no</email_notification>}, 'and the rest of our configuration' );
    like( $out, qr{<port>10514</port>},                          'all of it' );
    unlike( $out, qr{bogus\@test[.]test}, 'and nothing else of the package' );
};

subtest 'what it refuses' => sub {
    my $none = file( 'none.conf', "<ossec_config>\n  <!-- <rules><include>x_rules.xml</include></rules> -->\n</ossec_config>\n" );
    like(
        exception {
            capture { Trog::OssecPackageRules::main( $none, $ours ) }
        },
        qr/has[ ]no[ ]<rules>/,
        'a package configuration with no rules, other than in a comment'
    );

    my $empty = file( 'empty.conf', "<ossec_config>\n  <rules>\n  </rules>\n</ossec_config>\n" );
    like(
        exception {
            capture { Trog::OssecPackageRules::main( $empty, $ours ) }
        },
        qr/includes[ ]no[ ]rule[ ]file/,
        'one whose rules include nothing'
    );

    my $nowhere = file( 'nowhere.conf', "<ossec_config>\n</ossec_config>\n" );
    like(
        exception {
            capture { Trog::OssecPackageRules::main( $package, $nowhere ) }
        },
        qr/\Q$nowhere\E[ ]has[ ]no[ ]<rules>/,
        'and our configuration with no place to put them'
    );
};

had_no_warnings();
done_testing();
