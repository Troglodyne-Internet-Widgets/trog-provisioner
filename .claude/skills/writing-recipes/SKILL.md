---
name: writing-recipes
trigger: Writing a new Provisioner::Recipe or changing what an existing one takes -- its args(), its defaults, how it validates configuration, and where the line falls between the schema and the code.
description: |
  What belongs in args() and what belongs in perl.  The schema validates,
  defaults and documents for free, and the recurring mistake is to do one of
  those jobs somewhere else -- so this is mostly about resisting that, and about
  the one construct that makes a default land where you meant it to.
---

I'm using the writing-recipes skill to write or change a recipe's configuration.

`perldoc Provisioner::Recipe` is the method list and what each one is for.  This
is the part that is not written down there: which of them a thing belongs in,
and why the answer is nearly always `args()`.

## The schema is the recipe's source of truth

`args()` returns an OpenAPI v3 schema, and `validate()` runs it through
`JSON::Validator` with `defaults => 1`.  That gets you four things at once:

- **validation** -- a type, an `enum`, a `minimum`, and a configuration that
  breaks them fails the build rather than the guest,
- **defaults** -- filled in for you, at whatever depth you declare them,
- **coercion** -- booleans, numbers and strings arrive as what you said they
  were,
- **documentation** -- the schema is the answer to "what does this recipe
  take", and `bin/recipes` prints it.

Every line of perl that checks, fills in or normalises a configuration value is
a line competing with one of those.  Usually it loses quietly: the schema is
what `bin/recipes` shows an operator and what a reader believes, so a value the
code fills in behind it is a value nobody can find out about.

**So the question to ask of anything you are about to write in `enrich` is:
which schema construct says this?**  Most of the time there is one.

## Put a default at the level of the thing it defaults

This is the one that has actually gone wrong, and it is worth knowing by heart.

A `default` means *"when this key is absent"* -- absent from the object it is
declared in.  Put it one level too high and it describes the wrong absence:

    # Wrong.  This says "when nobody supplied rate_limits at all, use this map".
    rate_limits => {
        type    => 'object',
        default => { 22 => 64 },
    },

    # Right.  This says "when this map has no 22 in it, put one there".
    rate_limits => {
        type       => 'object',
        default    => {},
        properties => {
            22 => { type => 'integer', default => 64 },
        },
    },

The difference only shows when something else supplies the key.  `rate_limits`
arrives from `required_recipes`, handed over whole -- so on the first version,
the moment any recipe listened on anything the key was present, the default
never fired, and ssh went unlimited on every guest that had a listening recipe.
Nothing errored.  The schema documented an intention that never happened, which
is the failure mode this whole file is about.

The same trap is waiting anywhere a value is a map or a list that more than one
thing contributes to.  If a field can arrive from `required_recipes`, from
`reconcile`, or from an operator, its defaults belong on its *members*.

## Check it rather than reasoning about it

A schema question is answerable in a minute, and reasoning about validator
behaviour is how the above got written in the first place.  Put the cases in a
script and look:

    perl -Ilib -MProvisioner::Recipe::ufw -e '
      my $r = Provisioner::Recipe::ufw->new(
          output_dir => "/tmp/x", libdir => ".", target_packager => "deb" );
      for my $case ( {}, { rate_limits => { "1194/udp" => 256 } } ) {
          my %o = $r->validate(%$case);
          print join( ",", map { "$_=$o{rate_limits}{$_}" }
                           sort keys %{ $o{rate_limits} } ), "\n";
      }'

Two lines of output settle what a paragraph of argument will not.  Do this
before you conclude the schema cannot express something.

## What enrich is actually for

`enrich` runs *after* validation, on a deep copy, and it is for the things a
schema genuinely cannot say:

- **A value derived from another value.**  `ufw` puts the hypervisor into
  `admin_networks`, because the guest fetches its payload from there over ssh
  repeatedly and no operator should have to know that.
- **A value that depends on the machine.**  Anything only the guest or the
  fleet can answer.
- **A shape the validator has no vocabulary for.**  Rare.  Look twice.

Two consequences of running after validation, both of which have caught people:

- It **cannot satisfy a `required` field**.  A required field nothing fills in
  is the operator's to supply -- see the `provisioning-recipes` skill on why the
  answer to that is to ask rather than to default it quietly.
- Its output is **not validated**.  Whatever `enrich` puts in is what the
  templates get, unchecked.  That is a reason to keep it small, and a reason
  not to use it for something a `type` would have caught.

## When two recipes disagree

That is `reconcile` and `resolve_conflict`, not something to hand-roll in
`enrich` either -- `perldoc Provisioner::Recipe` has both, and
`Provisioner::Recipe::ufw` is the worked example: it takes the higher of two
rate limits and dies on anything else, because a limit is the one field where
picking a side is defensible.

Note what the key is when you write one.  `53` and `53/udp` are two limits
rather than one, because the key is the port *and* the protocol -- so a
conflict resolver keyed on the whole string needs no special case for them.

## Packages are not configuration

`deps()` is the one method that does not live in the recipe.  A package name is
a fact about a distribution, so it goes in that distribution's version of the
recipe -- `Provisioner::Recipe::Ubuntu::nginx`, a subclass of
`Provisioner::Recipe::nginx`, holding a `deps()` and nothing else.  The recipe
itself keeps everything that is true wherever it is installed.

The failure to know about is quiet: a recipe with no subclass for the
distribution in hand inherits the base class's empty `deps()` and installs
nothing at all.  `t/recipes.t` asserts every recipe that needs packages has them
for every distribution there is, which is what turns that into a test failure
rather than a service that will not start twenty minutes into a build.

## The rest of writing a recipe

Not repeated here, because it is written down:

| | |
|---|---|
| `perldoc Provisioner::Recipe` | the methods, the fragment-is-a-makefile rules, generated files, tests |
| [docs/APPROACH.md](../../../docs/APPROACH.md) | sockets, SSL, target ordering, waiting on things |
| `provisioning-recipes` skill | what tends to be wrong, and building a guest to find out |
| [t/TESTING.md](../../../t/TESTING.md) | what a test is for here |

Two of those are worth naming anyway because they are where a schema change
shows up next:

- **`t/recipes.t` renders every recipe and every guest test.**  Run it after
  touching `args()`; a default that breaks a template breaks it there.
- **A recipe is verified on a guest.**  A schema that validates is not a recipe
  that works, and the `provisioning-recipes` skill is how you find out which
  you have.
