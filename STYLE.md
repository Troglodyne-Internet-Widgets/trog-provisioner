# Perl Style

Use `perltidy` on your perl code when done editing, we have a .perltidyrc

## Characters and UTF-8

Never use any kind of character but ASCII in perl source files, nor in templates.
Never `use utf8`.
Never `use feature 'unicode_strings'.

If you must convert from chars to octets or vice versa, use the facilities in the `Encode` module.

## Imports and Dependencies
- Always use `strict` and `warnings FATAL => 'all'`
- Use `parent` for inheritance, not `use base`
- Group imports logically: core modules first, then CPAN modules, then stuff in lib/
- `use feature 'signatures'`, and convert traditional perl subroutines where feasible.
- `use feature 'state'` when you need to memoize variables for performance.
- Otherwise avoid features.

## Naming Conventions
- Package names: `Provisioner::Recipe::recipename` (lowercase recipe names)
- Subroutines: lowercase, snake\_case (e.g., `remote_files`, `template_files`)
- Variables: lowercase, snake\_case
- Constants: UPPERCASE, snake\_case

## Error Handling
- Use with descriptive messages for fatal errors
- Use Carp::Always to make sure we get stack traces
- Include context in error messages: `die "Could not open $file: $!"`
- Validate inputs early in subroutines

## Control flow & Cyclomatic Complexity
Structure code to avoid deeply nested blocks.

- Prefer fall-throughs and short-circuits to if..else.
- Prefer postfix if/unless when only one thing needs to be done in response to a condition
- Prefer map/grep/any/reduce to using loops when transforming arrays.  any & reduce are in List::Util.

Example:
```perl
use List::Util qw{any};
sub do_stuff {
    return 'blahblah' if $condition;

    if ($other_condition) {
        do_other_thing();
        return 'bazbaz';
    }

    return 'ezbez' if (any { $_ eq $list_condition } @_);

    # Main function body proceeds from here
    ...
}
```

## POD Documentation
```perl
=head1 Provisioner::Recipe::example

=head2 SYNOPSIS

    somedomain:
        example:
            option: value

=head2 DESCRIPTION

Brief description of what this recipe does.

=head3 subroutine_name

What it does.

=over 1

=item INPUTS: parameter descriptions

=item OUTPUTS: return value description

=back

=cut
```
## Scripts in bin/

Leverage `Pod::Usage::usage()` to produce `--help` output.

Use `Getopt::Long::GetOptionsFromArray()` to parse args.

Always follow the modulino pattern (script has a package declaration, and executes `main(@ARGV) unless caller;` at the end of the script to run.
