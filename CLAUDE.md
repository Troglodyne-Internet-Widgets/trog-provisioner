# CLAUDE.md

This file is the procedure for work in this repository.  Other documents say
what the code is and how it is written.  This file points at them below.

`bin/new_config` turns the recipes named for a domain into a makefile.
`bin/provision` builds a guest and runs it.  `bin/destroy` takes a guest away.
Everything else is a recipe, a template that a recipe renders, or a library
that those three share.

## Which skills, and when

The hooks of the perl-slop plugin hold you to the procedure.  They refuse an
edit to Perl until `perl-slop:reading-perl` is loaded.  They refuse a commit of
Perl until `data-perl`, `testing-perl` and `reviewing-perl` are loaded, each
one after the last commit.  `.perl-slop.json` adds the skills of this
repository.  It asks for `writing-recipes` before an edit under
`lib/Provisioner/Recipe/`.  It asks for `provisioning-recipes` before a commit
that changes a recipe or a template.  A refusal names the skills that are
missing.  The sections below say why each skill is there.

The hooks cannot see one case.  Before you answer a question about the code,
or look for something in it, load `perl-slop:reading-perl`.  Load it for that
as well as before an edit.

## Read the code before you change it

Most of the code here is older than the conversation about it.  A line that
looks pointless is usually the scar of something that went wrong once.  The
reason is in the commit, not in the file.  So read before the first edit, not
after the tests fail.

## Where it is written down

`README.md` starts with a table of every document here and the question that
each one answers.  These are the documents to keep at hand:

| | |
|---|---|
| `AGENTS.md` | build and test commands, recipe anatomy, template style |
| `STYLE.md` | how the perl is written, and `perltidy` |
| `t/TESTING.md` | what a test is for here, and what kind to write |
| `docs/APPROACH.md` | the choices a recipe is expected to make |
| `perldoc Provisioner::Recipe` | fragments, generated files, tests, and the three ways a makefile fragment is not a shell script |

`Provisioner::Cookbook` answers every question about configuration.  It says
which recipes exist, what each one takes, how a domain is configured, and
where the data of a domain is.  Do not read `recipes.yaml` or merge `_base`
yourself.  A copy of that logic in the teardown of a skill once disagreed with
`bin/new_config` about the directory that held the data of a domain.

## What a recipe takes belongs in its schema

`args()` validates, sets defaults, coerces and documents, with no extra code.
The mistake that recurs here is to do one of those jobs in perl instead.  Then
`bin/recipes` cannot show it, and a reader cannot find it.  The
`writing-recipes` skill is mostly about how to avoid that.  It also explains
the construct that decides where a default lands.  The ssh rate limit of ufw
once had its default one level too high.  So the limit did not apply on any
guest that ran a recipe that listens.

## A recipe is tested on a guest

`t/recipes.t` proves that a template renders.  It does not prove that the
package exists, that the service starts, or that the makefile target succeeds.
So build a change under `lib/Provisioner/Recipe/` or `templates/` on a guest
before you commit it.  The `provisioning-recipes` skill says how.

After every run, tear the guest down, also after a failure.  If a run ended
without a teardown, this command finds what it left:

    bin/destroy --orphans --dryrun

A run can also leave git worktrees.  An agent with its own worktree gets a full
copy of the repository under `.claude/worktrees/`.  If nothing in a worktree
changed, Claude Code removes it.  Otherwise the worktree stays, so every
fan-out that did work leaves its copies there.  Git ignores them, and nobody
lists a dot directory.  When both of these are true, invoke the
`agent-worktrees` skill:

```
du -hs .claude/worktrees          # over 1G
df -h  .claude/worktrees          # 80% or worse
```

The skill says what is safe to remove, and what the lock file means.  Do not
remove them by hand.  An unpushed branch can exist in one of those directories
and nowhere else.  `git worktree remove --force` deletes such a branch with no
warning.

## Finishing a changeset

The commit gate asks for three skills.  Apply them in this order: data-perl,
testing-perl, then reviewing-perl against the whole diff.  To load a skill is
not to apply it.  The hook sees the load, and the review is still your job.

Then run `podchecker` on each changed file.

Do not run `perltidy`, `perlcritic` or `perl -c` yourself.  Do not run the
tests to decide whether a change is ready to commit.  The pre-commit hook
tidies the Perl that you staged, runs perlcritic on it with the right profile
for its path, and compiles it.  Then it runs the tests that the commit can
break, which `tests-covering` chooses.  If a step fails, the hook stops the
commit and prints the reason.

The hook names each test that failed.  Its output does not say why.  If a test
fails, run that file yourself with `-v`, and read the output:

    prove -v t/<file>.t

Do the same to see a new test fail before you fix what it tests.

In each working tree that you commit from, install both hooks once:

    cp git-hooks/pre-commit git-hooks/post-commit .git/hooks/

The post-commit hook updates the records of `tests-covering` in the
background.

A file that no test loads, such as a template, gets its tests from
`.tests-covering-map.pl`.  A path that the map cannot place runs every test.
If a commit runs the whole suite but does not touch everything, the map
probably needs a rule.  In the same change, add the rule to
`.tests-covering-map.pl`, and add the case to `t/tests-covering-map.t`.

`git-hooks/pre-commit` says which profile judges which path.  It also says why
`scripts/` has a profile of its own.

## When something is slow

Use `perl-slop:profiling-perl`.  Measure before you conclude anything, and
measure again after a change.  "It is just slow" is not a finding.  A line
number and a percentage is a finding.

This is most important for a failure that looks like a timeout on a provision.
A remote provision has several layers of timeouts.  Sometimes a failure comes
at a round interval.  If it does not move when you raise the setting, a
different timeout fired, not the one that you set.  Find out which timeout
fired before you conclude anything about the guest.  The
`provisioning-recipes` skill lists the timeouts that caused trouble here.

## Commits and pull requests

Make a branch.  Do not commit to `master`.

A commit message here says what was wrong and why the change fixes it.  Write
it in prose and in the imperative mood.  Name the behavior, not the diff, for
example "Ask the pool whether it takes O_DIRECT, rather than guessing from its
name".  The message has a job.  `perl-slop:reading-perl` describes a person who
finds your line with `git blame` two years from now.  The message is the only
thing that can still tell that person why.  For the same reason, the why goes
in the message and not in a comment.

After you make sure that something works, say what you ran and what it
said.  A claim that a guest came up needs the log line that shows it.  A claim
about your own work needs its evidence too, such as the URL from `gh pr
create` or the sha from `git push`.  A PR number that nobody can open is worse
than no number.

Quote that line with the names taken out.  The line `ok 3 - $domain trusts the
host keys of $forge` proves the same thing as the line with the real names.
The evidence is that the assertion ran and passed, not which installation ran
it.  This repository is public, and the fleet that it runs on is not.  People
who read a commit message, a PR description or an issue must not learn the
hostnames, the accounts, the addresses or the customers.
`perl-slop:information-security` has the full rule.

If the code of a branch depends on another branch, stack it on that branch.
If only a test of it depends on the other branch, do not stack it.  The tcms
branch once needed the postrun fix before a guest went green.  So its PR went
against the postrun branch, although it changed none of the same files.  That
branch had already delivered its changes to `master`, so the PR merged into it
and stayed there.  Open every PR against `master`, and say in the description
what must merge first.
