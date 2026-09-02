---
name: patchset-review
description: Review a finished patchset against Troglodyne house style before handing it over. Use after producing any multi-file change to this repo, and before committing or opening a PR.
---

# Patchset review

Run this on your own work once the patchset is finished and the tests pass, but
before you commit or open a PR. It is a self-review pass: read the whole diff
back, check it against everything below, and fix what it turns up rather than
reporting it.

Start with `git diff` (or `git diff master...HEAD` for a branch) and read every
hunk. Then check each of the following. Every one of these came out of a real
review comment on this repo, so treat a hit as something to fix, not something
to justify.

## Don't repeat yourself

- **No per-script copies of shared state.** If two scripts each declare
  `our $thing;` and a `sub thing { $thing //= Build->new(); }` accessor, the
  memoization belongs in the class, not in the scripts. Make the constructor a
  singleton and let every caller just say `Class->new()`.
- **No re-deriving what an object already knows.** If a script computes a path
  from an object's fields, that computation is a method on the object.
- **Look for the same block twice.** Two scripts with a near-identical sub is a
  method that hasn't been written yet.

## Encapsulate

- **Ask what owns the data.** Free subs in a script that take an object as their
  first argument (`sub tf_dir_for { my ($hv, $override) = @_; ... }`) are methods
  wearing a disguise. Move them.
- **Package globals are a smell.** `our $domain_dir` threaded through eight subs
  is a field on the object those subs already have in hand.
- **Push knowledge down, not up.** A script should say *what* it wants
  (`$hv->annihilate_domain($name)`), never *how* to get it
  (`system(qw{virsh destroy}, $name)`).

## Use the library, not the shell

- **Prefer a real API over shelling out.** `Sys::Virt` over `virsh`, and the
  same reasoning everywhere else. Shelling out means parsing human-readable
  output, quoting by hand, and losing the error.
- When you genuinely have to shell out, say in a comment *why* the API can't do
  it. (Example: libvirt exposes DHCP leases read-only, so releasing one means
  the lease helper.)

## Perl style

- **`use FindBin::libs`, never `use lib`.** Enforced by
  `Perl::Critic::Policy::ProhibitUseLib`.
- **POD and `Pod::Usage`, never a `usage()` sub.** Document the synopsis and
  options in POD and print them with `pod2usage`; a hand-rolled `usage()` is a
  second copy of the interface that goes stale. Enforced by
  `Perl::Critic::Policy::ProhibitUsageSubs`.
- **`qw{}` for runs of literals.** `system_hv(qw{sudo rm -f}, $conf)`, not
  `system_hv('sudo', 'rm', '-f', $conf)`. Enforced by
  `Perl::Critic::Policy::RequireQwForLiteralLists`.
- **No ternaries that pick between two spellings of the same call.**
  `$hv->is_local ? unlink($f) : $hv->system_hv(qw{rm -f}, $f)` means the
  abstraction is leaking; make the one call do both.

Run the house policies over the diff:

    perlcritic --profile .perlcriticrc bin/ lib/ t/

Those three live in their own distributions, alongside
`Perl::Critic::Policy::ProhibitPipeOpen`, under
https://github.com/Troglodyne-Internet-Widgets/ -- install them if perlcritic
says it has no such policy.

## Unstated dependencies

- **Ask what else has to be true.** A change that syncs one file to another
  machine should make you ask what else on that machine the far side reads.
  Things provisioned outside this repository are the easiest to miss precisely
  because nothing here mentions them.
- Anything you assume but can't enforce goes in a comment, the POD, or the
  Readme — whichever the next person will actually read.

## Tests

- Every behavior the patchset added or changed has a test.
- Tests don't need a live hypervisor, a real network, or root.
- If you moved a sub between packages, its tests moved with it.

## Finally

Run the suite (`prove -Ilib t/`) and make sure every script still compiles
(`perl -Ilib -c`) before you call it done.
