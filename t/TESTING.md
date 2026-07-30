# Testing the troglodyne way

## Definitions

The purpose of a test is to formalize the system under test's *functional* and *non-functional* characteristics.

1. Functional characteristics are *cardinal*.     There exists a closed form solution to this problem; a definitive answer.
2. Non-Functional characteristics are *ordinal*.  There isn't a *wrong* answer, simply better or worse.  Ex. Performance, Accuracy of Approximations, Matters of Taste

A test is one of three types:

1. Structural / Unit : mocks or fakes all *direct* dependencies of the subroutine under test.
2. Integration : mocks or fakes all *indirect* dependencies of the subroutine under test; dependencies of our direct dependencies.
3. Acceptance : uses no mocks of any kind, but fakes of external systems are acceptable.  Only for testing non-functional characteristics.

Mocks are redefined variables or subroutines in particular perl packages we depend on directly or indirectly.
Fakes are generally things external to our program which we nevertheless interact with dummied up for testing purposes.

Fakes of things external to the system under test are mandatory for unit and acceptance tests.

Acceptance tests must not run without sandboxing of some kind; be it VMs, containers or jails.

It is preferrable that acceptance tests are *data-driven*, which is to say they accept some kind of data and feed it into the system under test.
It is preferrable for data driven tests to accept input on STDIN, but fall back to a `__DATA__` section when not provided.

In the perl context we are going to be testing 4 types of systems:

1. Perl Modules - these generally live in lib/ and have a .pm file extension. They must exit 1.
2. Modulinos    - these generally live in bin/ and are chmod +x,  declare a package and only execute `main()` when `caller()` is defined.
3. Scripts      - these generally live in scripts/, and have a .pl extension.
4. Applications - usually PSGI, these are intended to be run as a part or plugin of other perl applications.

Going forward we will abbreviate "system under test" as SUT.

## Implications on design of SUT

Most globals should be declared with `our` rather than `my` so that they can be locally overridden in tests.
Execution of external programs via `system` or `qx` and other builtins should be wrapped in a subroutine, so that it can be easily mocked.
In general "shelling out" should be avoided in favor of library and builtin equivalents for testing and performance reasons.
Code re-use (modularity) cuts down on unnecessary testing as it means less lines to cover.  DRY (Do not repeat yourself).

## Structure

Every test MUST be named in the following form:

My-Module.t

Where lib/My/Module.pm is the system under test.

It is important to keep unit tests associated with the module that they test.

Similarly, it is important to test each subroutine in its own subtest / closure,
so as much local state and mocks as are possible can expire with the test of the particular sub.

All tests belong in `t/`
Integration tests must skip unless the `RELEASE_TESTING` env var = 1
Acceptance tests must skip unless  the `AUTHOR_TESTING` env var = 1

## Approach to writing tests

Load the system under test with either `use_ok()` for modules, or require\_ok() for modulino binaries. Only use `ok do ...` when testing nonmodlino scripts.

Make no assertions verifying that dependencies are present in tests, ensure they are in Makefile.PL (or dist.ini if using Dist::Zilla) instead.

The only acceptable means of mocking subroutines is Test::MockModule in strict mode; use redefine() or define() as appropriate.

Whenever possible fake files using Test::MockFile.
Any deps of the SUT which do file access in BEGIN blocks will have to be `use`d in the test itself.
Any deps which use bareword filehandles will also require this treatment, and any files they access cannot be mocked via MockFiles.
Test::Mockfile must be the last dependency loaded in the test.

Prefer `Test2::V1 -i` over using Test::More where possible.

Use FindBin::libs to enable testing libdirs.

Use Test::NoWarnings or Test2::Plugin::NoWarnings as appropriate.
This may be omitted for scripts and modulinos, as it is expected that they may emit warnings.

It is acceptable for the system under test to `die()` during tests; in general we want negative results as fast as is possible.

When you are specifically testing for a termination condition, use Test::Fatal or Test2::Tools::Exception as appropriate

# Running tests

Run tests with `prove -lm -j8`

# Nature of fake data

When you need a domain name, use `test.test` or a subdomain thereof.  Never use `example.com`.

Avoid any remotely plausible file path names where possible (example: /bogus).
If a test results in unintended system modifications this helps make them obvious.
