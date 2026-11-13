#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Trog-Patterns.t - Trog::Patterns: each name, as a regular expression and as the pattern of a schema

=head1 DESCRIPTION

Each variable is asked about the names at its edges twice: as the compiled
expression that code matches with, and as the string that a schema takes,
through JSON::Validator, which is where a pattern used to lose C</aa> and
accept a newline at the end.

=cut

use Test::More;
use JSON::Validator();

use FindBin::libs;
use Trog::Patterns();

# Each variable, then the names at its edges: the name, whether it matches, and
# what it is.
my %CASES = (
    ACCOUNT_NAME => [
        $Trog::Patterns::ACCOUNT_NAME,
        [ 'bob',                                   1, 'a user' ],
        [ '_svc-2',                                1, 'with _, - and a digit' ],
        [ 'a' . 'b' x 31,                          1, '32 bytes, the most that useradd takes' ],
        [ 'a' . 'b' x 32,                          0, '33 bytes' ],
        [ "bob\n",                                 0, 'a newline at the end' ],
        [ 'Bob',                                   0, 'an upper-case letter' ],
        [ '1bob',                                  0, 'a digit first' ],
        [ 'bo b',                                  0, 'a space, which sudoers reads as two words' ],
        [ "b\N{LATIN SMALL LETTER E WITH ACUTE}b", 0, 'a letter that is not ASCII' ],
    ],
    LINK_NAME => [
        $Trog::Patterns::LINK_NAME,
        [ 'br0',                                   1, 'a bridge' ],
        [ 'a' x 15,                                1, 'fifteen bytes, the most that the kernel takes' ],
        [ 'virbr1.10_x-y',                         1, 'with each of _ . and -' ],
        [ q{},                                     0, 'nothing' ],
        [ 'a' x 16,                                0, 'sixteen bytes' ],
        [ '-br0',                                  0, 'a first character that is not a letter or a digit' ],
        [ 'br/0',                                  0, 'a slash, which a path reads' ],
        [ 'br:0',                                  0, 'a colon, which the address of an alias reads' ],
        [ "br\N{LATIN SMALL LETTER E WITH ACUTE}", 0, 'a letter that is not ASCII' ],
        [ "br\N{ARABIC-INDIC DIGIT ONE}",          0, 'a digit that is not ASCII' ],
    ],
    GITHUB_LOGIN => [
        $Trog::Patterns::GITHUB_LOGIN,
        [ 'teo-desian', 1, 'with a hyphen' ],
        [ 'a',          1, 'one character' ],
        [ 'a' x 39,     1, '39 characters, the most that GitHub takes' ],
        [ 'a' x 40,     0, '40 characters' ],
        [ '-a',         0, 'a hyphen first' ],
        [ 'a-',         0, 'a hyphen last' ],
        [ 'a_b',        0, 'an underscore' ],
        [ 'a.b',        0, 'a dot' ],
        [ "bob\n",      0, 'a newline at the end' ],
    ],
    GITHUB_REPO => [
        $Trog::Patterns::GITHUB_REPO,
        [ 'Owner/Name',     1, 'an owner and a name' ],
        [ 'o/a.b_c-d',      1, 'a name with . _ and -' ],
        [ 'o/..x',          1, 'a name that starts with two dots' ],
        [ 'o/' . 'a' x 100, 1, 'a name of 100 characters' ],
        [ 'o/' . 'a' x 101, 0, 'a name of 101 characters' ],
        [ 'o/.',            0, 'a name of one dot' ],
        [ 'o/..',           0, 'a name of two dots' ],
        [ '../x',           0, 'an owner of two dots' ],
        [ 'o',              0, 'no name' ],
        [ 'o/a/b',          0, 'a second slash' ],
        [ "o/a\n",          0, 'a newline at the end' ],
    ],
    COMMIT_EMAIL => [
        $Trog::Patterns::COMMIT_EMAIL,
        [ 'bot@test.test',    1, 'an address' ],
        [ 'a@b',              1, 'one character on each side' ],
        [ '@test.test',       0, 'nothing before the @' ],
        [ 'bot@',             0, 'nothing after it' ],
        [ 'b ot@test.test',   0, 'a space' ],
        [ q{b'ot@test.test},  0, 'a quote' ],
        [ 'b\\ot@test.test',  0, 'a backslash' ],
        [ "bot\@test.test\n", 0, 'a newline at the end' ],
    ],
    DOTTED_VERSION => [
        $Trog::Patterns::DOTTED_VERSION,
        [ '5.40.1',   1, 'three numbers' ],
        [ '10.11.12', 1, 'numbers of two digits' ],
        [ '5.40',     0, 'two numbers' ],
        [ '5.40.1.2', 0, 'four numbers' ],
        [ 'v5.40.1',  0, 'a v first' ],
        [ "5.40.1\n", 0, 'a newline at the end' ],
    ],
    INFLUX_DURATION => [
        $Trog::Patterns::INFLUX_DURATION,
        [ '48h',                          1, 'hours' ],
        [ '1w',                           1, 'a week, the largest unit' ],
        [ '30s',                          1, 'seconds, the smallest' ],
        [ '48',                           0, 'no unit' ],
        [ 'h',                            0, 'no number' ],
        [ '1h30m',                        0, 'two units' ],
        [ '1y',                           0, 'a unit that InfluxDB does not take' ],
        [ "48h\n",                        0, 'a newline at the end' ],
        [ "4\N{ARABIC-INDIC DIGIT ONE}h", 0, 'a digit that is not ASCII' ],
    ],
);

foreach my $name ( sort keys %CASES ) {
    subtest "\$$name" => sub {
        my ( $re, @cases ) = @{ $CASES{$name} };
        my $schema = JSON::Validator->new->schema( { type => 'string', pattern => "$re" } );
        foreach my $case (@cases) {
            my ( $value, $ok, $what ) = @$case;
            is( $value =~ $re             ? 1 : 0, $ok, "the regular expression: $what" );
            is( $schema->validate($value) ? 0 : 1, $ok, "and the schema: $what" );
        }
    };
}

done_testing();
