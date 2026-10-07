#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/ldap-github-sync.t - the script that keeps the accounts of a GitHub
organization in the directory, which the ldap recipe installs

=cut

use Test::More;
use Test::Fatal qw{exception};
use Test::MockModule;
use Test::NoWarnings qw{had_no_warnings};
use MIME::Base64     qw{decode_base64};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../templates/files/ldap.github-sync";
require_ok($script);

my %CONF = (
    org         => 'someorg',
    base_dn     => 'dc=sync,dc=test,dc=test',
    admin_group => 'github-admins',
    admin_gid   => 10001,
    users_gid   => 10000,
    uid_base    => 1000000,
    api         => 'https://bogus.test.test',
    token       => 'throwaway',
);

# members, with GitHub answering by path.  A path that is not here is an error,
# as an answer that is not a 200 is in github_get.
sub members_given {
    my (%answers) = @_;
    my $mock = Test::MockModule->new( 'LdapGithubSync', no_auto => 1 );
    $mock->redefine(
        github_get => sub {
            my ( undef, $path ) = @_;
            die "GET $path: 502 Bad Gateway\n" unless exists $answers{$path};
            return @{ $answers{$path} };
        }
    );
    return LdapGithubSync::members( \%CONF );
}

my %ORG = (
    '/orgs/someorg/members?per_page=100'            => [ { login => 'Alice', id => 11 }, { login => 'bot-user', id => 22 } ],
    '/orgs/someorg/members?role=admin&per_page=100' => [ { login => 'Alice', id => 11 } ],
    '/users/alice/keys?per_page=100'                => [ { key   => 'ssh-ed25519 AAAAb' }, { key => 'ssh-ed25519 AAAAa' } ],
    '/users/bot-user/keys?per_page=100'             => [],
);

subtest 'members' => sub {
    my $members = members_given(%ORG);

    is_deeply( [ sort keys %$members ], [qw{alice bot-user}], 'each member, by the login in lower case, which is what an account is named' );
    is( $members->{alice}{admin},      1,  'an owner is an admin' );
    is( $members->{'bot-user'}{admin}, 0,  'and a member is not' );
    is( $members->{alice}{id},         11, 'with the id that the uidNumber comes from' );
    is_deeply( $members->{alice}{keys},      [ 'ssh-ed25519 AAAAa', 'ssh-ed25519 AAAAb' ], 'and the keys, sorted, so that a reorder on GitHub changes nothing' );
    is_deeply( $members->{'bot-user'}{keys}, [],                                           'a member with no keys has none' );
};

# Each of these would otherwise remove accounts that are still members.
subtest 'members changes nothing when GitHub did not answer every request' => sub {
    my %no_keys = %ORG;
    delete $no_keys{'/users/bot-user/keys?per_page=100'};
    like( exception { members_given(%no_keys) }, qr/502/, 'the keys of one member failed' );

    like( exception { members_given( %ORG, '/orgs/someorg/members?per_page=100' => [] ) }, qr/sees[ ]no[ ]members/, 'a token that sees no members' );

    like( exception { members_given( %ORG, '/orgs/someorg/members?per_page=100' => [ { login => 'bad/login', id => 1 } ] ) }, qr/not[ ]one/, 'a login that GitHub would not give out, which goes into a DN' );

    like( exception { members_given( %ORG, '/orgs/someorg/members?per_page=100' => [ { login => 'alice' } ] ) }, qr/no[ ]numeric[ ]id/, 'a member with no id' );

    like( exception { members_given( %ORG, '/users/alice/keys?per_page=100' => [ { key => "ssh-ed25519 AAAA\ndn: cn=evil" } ] ) }, qr/more[ ]than[ ]one[ ]line/, 'a key with a newline, which would be a second LDIF line' );
};

subtest 'github_get' => sub {
    my @asked;
    my %pages = (
        'https://bogus.test.test/x'        => { status => 200, content => '[1,2]', headers => { link => '<https://bogus.test.test/x?page=2>; rel="next", <https://bogus.test.test/x?page=2>; rel="last"' } },
        'https://bogus.test.test/x?page=2' => { status => 200, content => '[3]',   headers => {} },
    );
    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine( get => sub { my ( undef, $url ) = @_; push( @asked, $url ); return $pages{$url} // { status => 599, reason => 'Internal Exception', content => "could not connect\n", headers => {} } } );

    is_deeply( [ LdapGithubSync::github_get( \%CONF, '/x' ) ], [ 1, 2, 3 ], 'every page that the link header names' );
    is( scalar @asked, 2, 'and no page after the last' );

    like( exception { LdapGithubSync::github_get( \%CONF, '/y' ) }, qr/599.*could[ ]not[ ]connect/s, 'a request that never left says why' );

    $pages{'https://bogus.test.test/z'} = { status => 200, content => '{"message":"Not Found"}', headers => {} };
    like( exception { LdapGithubSync::github_get( \%CONF, '/z' ) }, qr/not[ ]answer[ ]with[ ]a[ ]list/, 'an answer that is not a list' );
};

my %MEMBERS = (
    alice      => { id => 11, admin => 1, keys => ['ssh-ed25519 AAAAa'] },
    'bot-user' => { id => 22, admin => 0, keys => [] },
    carol      => { id => 33, admin => 1, keys => ['ssh-ed25519 AAAAc'] },
);

subtest 'plan' => sub {
    my %people = (
        alice      => { mine => 1, keys => ['ssh-ed25519 AAAAold'] },
        'bot-user' => { mine => 1, keys => [] },
        carol      => { mine => 0, keys => [] },
        gone       => { mine => 1, keys => [] },
        seeded     => { mine => 0, keys => [] },
    );
    my $plan = LdapGithubSync::plan( \%CONF, \%MEMBERS, \%people, ['alice'] );

    is_deeply( $plan->{add},     [],        'a member with an account is not added again' );
    is_deeply( $plan->{update},  ['alice'], 'a member whose keys changed is updated' );
    is_deeply( $plan->{blocked}, ['carol'], 'a member with the name of an account this did not make is left alone' );
    is_deeply( $plan->{remove},  ['gone'],  'an account this made for somebody who left is removed, and an account it did not make is not' );
    is_deeply( $plan->{admins},  ['alice'], 'an owner whose account is in the way is no admin' );
    ok( !$plan->{group_change}, 'and a group that already says so is left alone' );

    $plan = LdapGithubSync::plan( \%CONF, \%MEMBERS, {}, undef );
    is_deeply( $plan->{add}, [qw{alice bot-user carol}], 'on an empty directory every member is added' );
    ok( $plan->{group_change} && !$plan->{group_exists}, 'and the group is made' );
};

# Records apart, with a base64 value decoded, as ldapmodify reads them.
sub records {
    my ($ldif) = @_;
    return map {
        [ map { m/\A([^:]+):(:?)[ ](.*)\z/ ? [ $1, $2 ? decode_base64($3) : $3 ] : () } split m/\n/ ]
    } split m/\n\n/, $ldif;
}

subtest 'ldif' => sub {
    my $plan    = LdapGithubSync::plan( \%CONF, \%MEMBERS, { gone => { mine => 1, keys => [] } }, undef );
    my @records = records( LdapGithubSync::ldif( \%CONF, $plan ) );

    my ($alice) = grep { $_->[0][1] =~ m/\Auid=alice,/ } @records;
    my %alice = map { $_->[0] => $_->[1] } @$alice;
    is( $alice->[0][1],       'uid=alice,ou=People,dc=sync,dc=test,dc=test', 'an account is under ou=People' );
    is( $alice{changetype},   'add',                                         'a new one is added' );
    is( $alice{uidNumber},    1000011,                                       'its uidNumber is uid_base and its id on GitHub' );
    is( $alice{gidNumber},    10000,                                         'its group is ldapusers' );
    is( $alice{description},  'github:someorg',                              'and it is marked as one this made' );
    is( $alice{sshPublicKey}, 'ssh-ed25519 AAAAa',                           'with its key' );
    ok( ( grep { $_->[0] eq 'objectClass' && $_->[1] eq 'ldapPublicKey' } @$alice ), 'and the class that allows the key' );

    my ($group) = grep { $_->[0][1] =~ m/\Acn=github-admins,/ } @records;
    is_deeply( [ map { $_->[1] } grep { $_->[0] eq 'memberUid' } @$group ], [qw{alice carol}], 'the group has the owners' );
    is( $records[-1][0][1], 'uid=gone,ou=People,dc=sync,dc=test,dc=test', 'the removals come last, after the group stops naming them' );
    is( $records[-1][1][1], 'delete',                                     'and remove the account' );
};

subtest 'line' => sub {
    is( LdapGithubSync::line( uid => 'alice' ), "uid: alice\n", 'a plain value goes as it is' );
    foreach my $value ( ' leading space', ':colon', '<less', "two\nlines", 'trailing ', 'caf' . chr(0xe9) ) {
        like( LdapGithubSync::line( cn => $value ), qr/\Acn:: /, "and one that LDIF cannot carry goes in base64: '$value'" );
    }
};

subtest 'ldap_search' => sub {
    my $mock = Test::MockModule->new( 'LdapGithubSync', no_auto => 1 );
    $mock->redefine( run => sub { return "dn: uid=alice,ou=People,dc=sync,dc=test,dc=test\nuid: alice\nsshPublicKey: ssh-ed25519 A\nsshPublicKey: ssh-ed25519 B\ndescription: github:someorg\n\ndn:: dWlkPWJvYixvdT1QZW9wbGU=\nuid: bob\n" } );

    my @entries = LdapGithubSync::ldap_search( 'ou=People', '(uid=*)' );
    is( scalar @entries, 2, 'each entry' );
    is_deeply( $entries[0]{sshPublicKey}, [ 'ssh-ed25519 A', 'ssh-ed25519 B' ], 'with every value of an attribute' );
    is( $entries[1]{dn}, 'uid=bob,ou=People', 'and a base64 DN decoded' );

    my $people = LdapGithubSync::people( \%CONF );
    ok( $people->{alice}{mine}, 'an account with the mark is one this made' );
    ok( !$people->{bob}{mine},  'and one without it is not' );
};

had_no_warnings();
done_testing();
