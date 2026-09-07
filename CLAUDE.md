# CLAUDE.md

How to work in this repository.  What the code *is* and how it is written are
written down elsewhere and pointed at below; this is the procedure.

`bin/new_config` turns the recipes named for a domain into a makefile,
`bin/provision` builds a guest and runs it, and `bin/destroy` takes one away.
Everything else is a recipe, a template one renders, or a library those three
share.

## Read the code before you change it

**When a request means consulting the code here at all -- answering a question
about it, tracking something down, or editing it -- invoke
`perl-slop:reading-perl` first.**

Most of what you will touch is older than the conversation about it, and the
line that looks pointless is usually the scar left by something that went wrong
once.  The reason is in the commit, not the file.  This is a reading pass, done
before the first edit rather than after the tests fail.

## Where it is written down

`README.md` opens with a table of every document here and what it answers.  The
ones you want in hand:

| | |
|---|---|
| `AGENTS.md` | build and test commands, recipe anatomy, template style |
| `STYLE.md` | how the perl is written, and `perltidy` |
| `t/TESTING.md` | what a test is for here, and what kind to write |
| `docs/APPROACH.md` | the choices a recipe is expected to make |
| `perldoc Provisioner::Recipe` | fragments, generated files, tests, and the three ways a makefile fragment is not a shell script |

Configuration questions have one answer: `Provisioner::Cookbook`.  What recipes
exist, what one takes, what a domain is configured with, where its data lives.
Do not read `recipes.yaml` or merge `_base` yourself -- that is how the copy in
the skill's teardown came to disagree with `bin/new_config` about which
directory a domain's data was in.

## A recipe is verified on a guest

`t/recipes.t` proves a template renders.  It says nothing about whether the
package exists, the service starts, or the makefile target succeeds.  For any
change under `lib/Provisioner/Recipe/` or `templates/`, invoke the
`provisioning-recipes` skill and build one.

Tear it down when you are finished, always, including after a failure.  If a run
ended without one, this finds what it left:

    .claude/skills/provisioning-recipes/scripts/teardown --orphans --dryrun

## Finishing a changeset

Before you commit, in this order:

1. **`perl-slop:data-perl`** -- is the data defined, coerced, validated and
   scoped the way perl wants it to be.
2. **`perl-slop:testing-perl`** -- does every behaviour you added or changed
   have a test, and is it the right kind.  Then run them.
3. **`perl-slop:reviewing-perl`** -- read the whole diff back against it.  This
   is the pass that catches the second copy of something the library already
   does, the shelling out, and the comment that belongs in the commit message.

Then the mechanical ones:

    perl -c <each changed .pm or bin/ script>
    perlcritic --profile .perlcriticrc bin/ lib/ t/
    podchecker <each changed file>
    prove -lm -j8 t/

`perltidy` runs itself, if the hook is installed: `cp git-hooks/pre-commit
.git/hooks/`.  Do that once, in any checkout you intend to commit from.

## Commits and pull requests

Branch, never commit to `master`.

A commit message here says what was wrong and why this is the fix -- in prose,
in the imperative, naming the behaviour rather than the diff ("Ask the pool
whether it takes O_DIRECT, rather than guessing from its name").  That is not
decoration: `perl-slop:reading-perl` is somebody arriving at your line in two
years with `git blame`, and the message is the only thing that will still be
able to tell them why.  Which is also why the *why* goes there rather than in a
comment.

When you have verified something, say what you ran and what it said.  A claim
that a guest came up is worth the log line that shows it.
