package Trog::Patterns;

#ABSTRACT: the regular expressions of the names that more than one place checks

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

Trog::Patterns - the regular expressions of the names that more than one place
checks

=head1 SYNOPSIS

    use Trog::Patterns();

    die "not a user name\n" unless $user =~ $Trog::Patterns::ACCOUNT_NAME;

    # In a schema, as a string.
    agent_user => { type => 'string', pattern => "$Trog::Patterns::ACCOUNT_NAME" },

=head1 DESCRIPTION

Each variable here is a compiled regular expression, anchored at both ends
with C<\A> and C<\z>, so that a name with a newline at the end does not
match.  Match with it as it is.  A schema takes it as a string,
C<"$ACCOUNT_NAME">: a compiled expression keeps its modifiers when it becomes
one, as C<(?^aasx:...)>, and JSON::Validator compiles the C<pattern> of a
schema as Perl.  So the C</aa> of this file reaches the schema, and
C<[[:alnum:]]> means ASCII there too.  A pattern written as a string in the
schema loses both.

A rule that one place checks stays in that place.  This module is for the
rules that two or more places must agree on.

=head1 VARIABLES

=head2 $ACCOUNT_NAME

A user or group name that useradd and groupadd take, and that sudoers reads as
one word: a lower-case letter or C<_>, then up to 31 lower-case letters,
digits, C<_> and C<->.

=cut

our $ACCOUNT_NAME = qr/\A [[:lower:]_] [[:lower:][:digit:]_-]{0,31} \z/;

=head2 $LINK_NAME

A name that the kernel takes for a link, such as a bridge: from 1 to 15 bytes,
of ASCII letters, digits, C<_>, C<.> and C<->, the first a letter or a digit.
So no name that it matches holds a character that a path or the address of an
alias would read.

=cut

our $LINK_NAME = qr/\A [[:alnum:]] [[:alnum:]_.-]{0,14} \z/;

=head2 $GITHUB_LOGIN

The login of a GitHub user or organization: up to 39 letters, digits and
hyphens, the first and the last not a hyphen.

=cut

# A login without its anchors, which $GITHUB_REPO starts with too.
my $LOGIN = qr/[[:alnum:]] (?: [[:alnum:]-]{0,37} [[:alnum:]] )?/;

our $GITHUB_LOGIN = qr/\A $LOGIN \z/;

=head2 $GITHUB_REPO

A repository on GitHub as C<OWNER/NAME>: the owner a L</$GITHUB_LOGIN>, and the
name up to 100 letters, digits, C<_>, C<.> and C<->, but not C<.> or C<..>,
which a path reads as this directory and the one above.

=cut

our $GITHUB_REPO = qr/\A $LOGIN \/ (?! [.]{1,2} \z ) [[:alnum:]_.-]{1,100} \z/;

=head2 $COMMIT_EMAIL

The address that a commit carries, as a configuration writes it into a quoted
string: no white space, no quote and no backslash, and an C<@> with something
on each side of it.

=cut

our $COMMIT_EMAIL = qr/\A [^\s"'\\]+ @ [^\s"'\\]+ \z/;

=head2 $DOTTED_VERSION

A version of three numbers, such as C<5.40.1>.

=cut

our $DOTTED_VERSION = qr/\A [[:digit:]]+ [.] [[:digit:]]+ [.] [[:digit:]]+ \z/;

1;
