# CLAUDE.md

How to work in this repository.  What the code *is* and how it is written are
written down elsewhere and pointed at below; this is the procedure.

`bin/new_config` turns the recipes named for a domain into a makefile,
`bin/provision` builds a guest and runs it, and `bin/destroy` takes one away.
Everything else is a recipe, a template one renders, or a library those three
share.

## Which skills, and when

The perl-slop plugin's hooks hold you to the procedure.  They refuse an edit
to Perl until `perl-slop:reading-perl` is loaded, and a commit of Perl until
`data-perl`, `testing-perl` and `reviewing-perl` are, each since the last
commit.  `.perl-slop.json` adds this repository's own: `writing-recipes`
before an edit under `lib/Provisioner/Recipe/`, and `provisioning-recipes`
before a commit that touches a recipe or a template.  A refusal names what is
missing.  The sections below say why each one is there.

One the hooks cannot see: load `perl-slop:reading-perl` before you answer a
question about the code or track something down in it, not only before you
edit it.

## Read the code before you change it

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

## What a recipe takes belongs in its schema

`args()` validates, defaults, coerces and documents, all of it for free, and the
recurring mistake here is to do one of those jobs in perl instead -- where
`bin/recipes` cannot show it and a reader cannot find it.  The skill is mostly
about resisting that, and about the construct that decides whether a default
lands where you meant it to: ufw's ssh rate limit was defaulted one level too
high, so it never applied on any guest that ran a recipe which listens.

## A recipe is verified on a guest

`t/recipes.t` proves a template renders.  It says nothing about whether the
package exists, the service starts, or the makefile target succeeds.  So a
change under `lib/Provisioner/Recipe/` or `templates/` is built on a guest
before it is committed, as the `provisioning-recipes` skill says.

Tear it down when you are finished, always, including after a failure.  If a run
ended without one, this finds what it left:

    bin/destroy --orphans --dryrun

A guest is not the only thing a run leaves behind.  An agent given its own
worktree gets a full checkout under `.claude/worktrees/`, and the harness only
reaps one it finds unchanged -- so every fan-out that did any work leaves its
checkouts there, ignored by git and under a dot directory nobody lists.  When
both of these are true:

    du -hs .claude/worktrees          # over 1G
    df -h  .claude/worktrees          # 80% or worse

invoke the `agent-worktrees` skill, which says what is safe to remove and what
the lock file does and does not mean.  Do not sweep them by hand: an unpushed
branch lives in one of those directories and nowhere else, and `git worktree
remove --force` is exactly the flag for throwing it away.

## Finishing a changeset

Apply the three skills that the commit gate asks for in this order: data-perl,
testing-perl, then reviewing-perl against the whole diff.  Loading a skill is
not applying it.  The hook sees the first, and the review is still yours.

Then the mechanical ones:

    perl -c <each changed .pm or bin/ script>
    perlcritic --profile .perlcriticrc         bin/ lib/ t/
    perlcritic --profile .perlcriticrc.scripts scripts/
    podchecker <each changed file>
    prove -lm -j8 t/

Two profiles, and the path decides which.  What is under `scripts/` ships to a
guest and runs on that guest's system perl, so it declares `use 5.014` where
everything else here declares `use 5.041` -- and `.perlcriticrc` leaves seven
policies out on the stated grounds that 5.041 makes them unnecessary, which is
not true one directory over.  `.perlcriticrc.scripts` names those seven and
drops what does not fit a script whose job is to drive ufw, iptables or cpanm.
`scripts/.perlcriticrc` is a link to it, so that a tool that looks for a
profile beside the file it lints, the editor included, finds the right one.

The hook does the tidy and both perlcritic lines for you, over the files you
staged, once it is installed: `cp git-hooks/pre-commit .git/hooks/`.  Do that
once, in any checkout you intend to commit from -- a commit a profile objects
to then does not happen.  `perl -c`, `podchecker` and the suite stay yours to
run.

## When something is slow

**`perl-slop:profiling-perl`.**  Measure before you conclude, and measure again
after you change something.  "It is just slow" is not a finding; a line number
and a percentage is.

That goes double for anything that looks like a timeout on a provision.  There
are layers of them in play on a remote one, and a failure at a suspiciously
round interval that does not move when you raise the setting is a failure fired
by a different timeout than the one you are configuring -- so establish which
one before concluding anything about the guest.  The `provisioning-recipes`
skill has the ones that have caught us.

## Commits and pull requests

Branch, never commit to `master`.

A commit message here says what was wrong and why this is the fix -- in prose,
in the imperative, naming the behavior rather than the diff ("Ask the pool
whether it takes O_DIRECT, rather than guessing from its name").  That is not
decoration: `perl-slop:reading-perl` is somebody arriving at your line in two
years with `git blame`, and the message is the only thing that will still be
able to tell them why.  Which is also why the *why* goes there rather than in a
comment.

When you have verified something, say what you ran and what it said.  A claim
that a guest came up is worth the log line that shows it.  So is a claim about
work you did: the URL `gh pr create` gave back, the sha `git push` reported.  A
PR number nobody can open is worse than no number.

Stack a branch on another only when the *code* depends on it, never when only
the verification does.  The tcms checkout needed the postrun fix before a guest
would go green, so its PR was opened against that branch -- while touching none
of the same files.  It merged into a branch that had already delivered its own
payload to `master`, and sat there.  Open against `master` and say in the
description what has to land first.
