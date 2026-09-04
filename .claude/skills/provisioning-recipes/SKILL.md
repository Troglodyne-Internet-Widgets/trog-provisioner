---
name: provisioning-recipes
trigger: Writing, changing or debugging a Provisioner::Recipe, when you need to know what it actually does on a real guest.
description: |
  Build a throwaway guest, run the recipe on it, and read back what happened.
  Uses a scratch configuration and a throwaway secret store so the real one is
  never opened, and collects the four logs that say what a recipe actually did.
---

I'm using the provisioning-recipes skill to check a recipe on a real guest.

A recipe that renders is not a recipe that works. `t/recipes.t` proves the
templates produce text; it says nothing about whether the packages exist, the
service starts, the firewall lets it out, or the Makefile target succeeds. The
only thing that answers those is a guest.

Use this when making or changing a recipe. Everything below is a helper in
`.claude/skills/provisioning-recipes/scripts/` — run them, don't reimplement
them.

## Before anything else

```
bin/preflight
```

Exits 0 if a run is worth starting, 1 if not, and prints what to fix. Every
check that fails still runs the rest, so you get the whole list in one go.

**If it reports no passwordless sudo, stop.** Print its guidance to the user and
go no further. Provisioning writes to the storage pool, defines domains and
edits the rsyslog config, all through sudo — a password prompt in the middle of
that has nowhere to be answered from, so the run *hangs* rather than failing,
and you will sit there until it times out. The fix is the user's to make: it is
a standing grant of root on a hypervisor, and not a decision to take for them.

Do not try to work around it. Not with `-t`, not by prompting, not by asking
them for the password. Say what preflight said and stop.

## Set up a scratch configuration

```
eval "$(.claude/skills/provisioning-recipes/scripts/scratch_config)"
```

This sets `TROG_PROVISIONER_CONFIG` and `TROG_SCRATCH_PASS` for the shell. Every
command after it must run with that variable set — if you run each `Bash` call
separately, re-export it or the tools will read `/etc/trog-provisioner` instead.

It copies `ipmap.cfg` and `recipes.yaml`, leaves `recipes.d/` empty, and builds
a KeePass DB holding a made-up value for every `secret:` reference in
`recipes.yaml`.

Two things about it worth understanding:

- **`recipes.d/` is empty on purpose.** `new_config` gathers secrets across
  every domain it can see, so copying the real `recipes.d/` would mean needing
  every password in the real store to build one throwaway guest.
- **The values are visibly fake** — `throwaway:group/entry/field`. A recipe that
  talks to a registrar or an API will fail at the point it tries. That is the
  intent. If a recipe needs a credential that actually works, that is a thing to
  tell the user about, not to solve by opening the real store.

The password is printed because `new_config` prompts for it. Feed it on stdin:

```
echo "$TROG_SCRATCH_PASS" | bin/provision "$DOMAIN"
```

## Build the guest

```
bin/new_guest <recipe> [<recipe> ...]
```

With no `--hostname` you get a UUID under `.test`. Take the name out of its
output — you need it for everything after.

If it reports anything to fill in, the recipe requires a field it has no default
for. Fill it with something plausible and say so in your report; a `CHANGEME`
left in place stops `new_config` by design.

Every domain gets a `data` recipe, and it rsyncs `/opt/data/$DOMAIN/` off the
hypervisor. Nothing creates that directory, so for a guest that has never
existed it is not there and the `data` target fails — taking the rest of the
Makefile with it, before any recipe you actually came to test has run. Make it
first:

```
perl -Ilib -MTrog::Hypervisors -e '
  my $hv = (Trog::Hypervisors->load(Trog::Hypervisors->default_path())->all)[0];
  $hv->mkpath("/opt/data/$ARGV[0]") or die "could not make the data dir\n"' "$DOMAIN"
```

Then:

```
echo "$TROG_SCRATCH_PASS" | bin/provision "$DOMAIN"
```

This takes minutes. It is finished when it says so or when it dies; if it dies,
**go straight to collecting artifacts** — a failed run is when they matter most.

## Read what happened

```
.claude/skills/provisioning-recipes/scripts/collect_artifacts "$DOMAIN"
```

Prints a directory holding whichever of these it found:

| file | what it answers |
|---|---|
| `$DOMAIN.setup.log` | the Makefile: every target, in order, and which one failed |
| `cloud-init.log`, `cloud-init-output.log` | everything before the Makefile — seed, packages, users, network |
| `new-outblocked.log` | egress the firewall stopped, as `SPT=`/`DPT=` pairs |
| `post_install.sh` | what was queued to run after the Makefile |

**Which ones are absent is itself the finding.** No `setup.log` means the guest
never got as far as running a Makefile — read `cloud-init-output.log` instead,
the answer is in there. "not there" means the file genuinely is not there: the
collector proves the connection before it reads anything, and dies rather than
reporting a guest it could not reach as a guest with no logs.

Read the whole `setup.log`, not just the tail. `make` keeps going through some
failures, so the first error is often thousands of lines above the last one.

Check `new-outblocked.log` whenever a recipe's own log shows a hang, a timeout
or a failed fetch. A recipe that needs egress it was never given a hole for
shows up there and nowhere else, and the symptom in its own log will look like
an unrelated network problem.

## When you find something, pin it with the guest's own test

Every recipe ships a test that runs **on the guest**, at the end of the
Makefile. `templates/tests/<recipe>.tt` is rendered into the domain's `t/` and
run by `prove -vm` as the Makefile's last target, so a recipe that provisions
but does not work fails the build.

That is the point of them, and it means a provisioning bug you find here has a
regression test with an obvious home. **When a run turns up a real problem, fix
the recipe and add the assertion that would have caught it**, in the same
patchset. `templates/tests/ufw.tt` is the shape:

```perl
my $ufw_status = `ufw status 2>/dev/null | head -1`;
chomp $ufw_status;
like($ufw_status, qr/active/i, 'ufw is active');
```

Assert on the thing that was broken, from the guest's point of view: the
service running, the port answering, the file present with the right contents,
the command on `$PATH`. Not that a template rendered — `t/recipes.t` covers
that, and it is exactly what did not catch this.

If the recipe has no `sub tests` yet, add one; it returns the template names,
the same way `template_files` does.

Then re-run the provision and check the test actually fails against the
unfixed recipe before you call it done. A regression test that never went red
is a regression test you are guessing about.

## Clean up

```
.claude/skills/provisioning-recipes/scripts/teardown "$DOMAIN"
```

**Always, including after a failure.** A half-built guest still holds an address
out of the pool, a disk in the storage pool and a definition in libvirt, and the
next run collides with all three. Collect the artifacts first — they are gone
after this.

## Reporting

Say what the recipe did, not that the script ran. Specifically:

- Whether the Makefile target succeeded, and if not, the actual error line.
- Anything in `new-outblocked.log`, since that is a `ufw` change, not a recipe
  change.
- Anything that only worked because a credential was fake, or only failed
  because it was.
- What you had to fill in, if `new_guest` asked for anything.

Quote the log lines that support each of those. A provision that succeeded is
one line; a provision that failed is worth the detail.

## What this does not tell you

The guest is fresh, on the `.test` TLD, with fake credentials, and nothing
depends on it. So it will not catch anything about upgrading an existing guest,
anything needing real DNS or a real registrar, anything about a recipe
interacting with a neighbour on the same host, or anything that only shows up
under load or over time. Say so rather than implying a clean run means more than
it does.
