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

Use this when making or changing a recipe. Everything below is either a tool in
`bin/` or a helper in `.claude/skills/provisioning-recipes/scripts/` — run them,
don't reimplement them. The split is whether it is useful outside this
procedure: `bin/preflight` and `bin/debug_boot` are, the scratch configuration
and its teardown are not.

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

## When the guest never comes up at all

`collect_artifacts` needs a guest with a shell. A guest that never boots has no
lease, no ssh and no logs, and `bin/provision` can only tell you it never asked
for an address. `bin/debug_boot` is for that.

**Start with `--console`.** It points the guest's serial port at a file on the
hypervisor, restarts it, and hands back every line the kernel and systemd
printed — as text, greppable, from the first line of firmware:

```
bin/debug_boot --console "$DOMAIN"
```

A hang is the last line before the silence. This beats screenshots, which show
the last page of an 80x25 console and nothing before it. `--fetch` re-reads the
capture without another restart; `--shot` grabs the screen as it is now.

**To get inside it**, read the disk directly — the guest does not need to boot,
or even be running:

```
bin/debug_boot --cat "$DOMAIN" /var/log/cloud-init.log
bin/debug_boot --ls  "$DOMAIN" /etc/netplan
```

**To get a shell on a guest that will not finish booting**, `--single` writes
`single` onto the kernel command line in the guest's own grub.cfg and starts it,
so it comes up in rescue mode on its own. The guest must be off first — it is a
write to its disk. Then `--vnc` prints the ssh tunnel to reach the console.

These three need libguestfs on the hypervisor; `bin/preflight` says whether it
is there and how to install it. Without it, `--hold` turns on the firmware boot
menu and `--keys` sends keystrokes, which is holding ESC by hand and about as
reliable — use it only as the fallback.

**`--restore` puts the domain and the disk back.** Unnecessary before a
teardown, which is the usual ending, but do it on anything you intend to keep.

## When a provision "times out"

A timeout is a claim about elapsed time, and there are layers of them in play on
every remote provision. Establish *which* one fired before concluding anything
about the guest.

**Check the elapsed time against the setting.** If a provision fails after a
suspiciously round interval -- ten minutes, exactly -- and raising the setting
changes nothing, the number you are configuring is not the number doing the
killing, and you need to look for the actually relevant timeout.

**Beware guards that only one path reaches.** `_unhang` returns early when the
hypervisor is local, so this never appeared against a local one. A guard on one
path means two code paths with different behaviour and only one of them getting
daily use.

**Do not conclude "it is just slow" from a truncated measurement.**
Such a conclusion requires evidence, and a performance analysis with specific
testable recommendations.  If such interventions fall short of fixing code that
is timing out, something is still wrong - you can't just conclude "it's slow".

## What tends to be wrong

Every one of these came out of provisioning a recipe and reading what happened.
Most are cheap to check statically, before spending ten minutes on a guest.

**A recipe fragment is a Makefile, not a shell script.** Everything a recipe's
`.tt` emits becomes a make recipe line, and that has three consequences that
have each broken a recipe here:

- Make eats a single `$` before the shell sees it, so shell expansions need
  `$$`. `postgres` asked apt for `postgresql-client-` this way, and a trailing
  dash is how apt spells *remove*.
- Each line runs in its own shell, so a variable set on one line is gone by the
  next. That is the same postgres bug, and `plexmediaserver` wrote its
  preferences file to `/Preferences.xml` for it.
- A command spanning lines needs `\` on every one of them, or make hands the
  shell an unterminated quote. `plexmediaserver` had a seven-line `python3 -c "`.
- A heredoc cannot work at all. `cat > file <<'EOF'` is one line, so it gets no
  body, and the lines meant to be the file are handed to sh one at a time as
  commands -- `matrix` wrote its register-admin script this way and died on
  `Syntax error: end of file unexpected (expecting "done")` from the `for` loop
  inside it. Render a script as a `template_files` entry and install it, which
  is what every other generated script here does.
- Make runs recipe lines under `/bin/sh`, which is **dash** on Ubuntu, not bash.
  `gogs` made its four directories in one brace expansion and got a single
  directory named `{repos,data,log,custom/conf}`, and wrote `id -u gogs
  &>/dev/null || useradd` — dash reads `&>` as a background `&` and a
  redirection, so the guard always succeeded and the `useradd` was dead code.
  Do not "fix" this by setting `SHELL := /bin/bash`: `makefile.tt` relies on
  dash's `echo` expanding `\n` when it writes sendmail's config.

**A template that moves a file `template_files` does not generate** kills the
target and everything after it. `deluged` and `matrix` both moved an nginx vhost
that no template produced — in both cases the vhost was `nginxproxy`'s, which
they already require.

**A template that uses a variable the recipe does not declare** renders it
empty. `nginxproxy` emitted `listen 443 ssl backlog=;`, which nginx refuses
outright.

**An apostrophe inside a `[%# ... %]` comment empties the rest of the file.**
Xslate lexes the inside of a directive, comments included, so `every domain's
aliases` opens a string that runs to the next quote and swallows everything
between — silently, with no error and a zero exit. The nginx vhost came out two
bytes long. `t/recipes.t` checks every template comment closes its quotes; run
it after editing one.

**A default on a field that is only true sometimes is wrong for everything
else.** `nginxproxy` defaulted `ssl` to true for every vhost, so a port 80 vhost
that asked for neither `ssl` nor `ssl_redirect` came out `listen 80 ssl` and
spoke TLS on the plain HTTP port. Its neighbour `ssl_redirect` had the default
removed for exactly this reason and the comment saying so was sitting right
above it.

**A URL nothing checks is a URL nobody has fetched.** Fetch every literal URL in
the templates and scripts; it takes a minute and it found three. `garage` took
its version and its binary from a GitHub mirror that has never cut a release.
`plexmediaserver` pointed at a host Plex retired, with a signing key that has
since been replaced by a different one -- so reaching the old host would not
have been enough either. And matrix's admin interface was still being fetched
under its old name: `synapse-admin` is `ketesa` now, and the release asset went
with it, so the admin vhost was serving an empty directory.

**A 403 is not always a refusal.** Every path under plex's old `/repos/` prefix
answered `403 AccessDenied` -- over IPv4 and IPv6 -- which read as the far end
blocking us. It was S3, which answers 403 rather than 404 for a key that is not
there when listing is denied. Ask for a path you know is missing on the same
host before concluding anything: `plex-keys/definitely-not-there` also 403'd,
while the real key returned 200.

**A file `template_files` generates that nothing installs** is dead. `ufw`
generates the rate limits it means to apply and has never installed them.

**A package name that is not in the archive is never installed and never
complained about.** Three were wrong here. Ask the archive, do not assume.

**A field cannot be both `required` and filled in by `enrich`** — enrich runs
after validation. `perl` required a user that only enrich could supply, so
anything depending on it could not build.

**`enrich` runs more than once, over the same nested hash.** Once for the
recipe's fragment and again for every template file it renders, and `%opts`
carries the same nested references each time — so anything it rewrites in place,
the next pass sees. `nginxproxy` rewrote a vhost's `proxy_uri` from a socket path
to an upstream name; the second pass saw something already starting with `http`,
skipped it, and rendered a vhost naming an upstream it no longer declared.
Write enrich so running it twice reaches the same answer, keeping what it needs
to do that.

**Find out where the service logs before guessing at it.** Three services here
send their reasons somewhere systemd never sees, so `systemctl` reports
`status=1/FAILURE` and the journal has nothing at any level: `gogs` with
`[log] MODE = file`, `pdns` through syslog into `/var/log/pdns.log`, and
`fail2ban` into its own log. The collector fetches those two files and reads the
journal at warning level; when a service still says nothing, change it to log to
the console rather than keep guessing -- setting gogs to `console, file` turned a
week of theories into one line naming the wrong config key.

**An assertion that cannot fail is a bug, and so is one that cannot pass.** Both
happened here in a day. `nvm` compared two empty strings; the perl test compared
a value with itself, because `$^V` inside backticks is interpolated by the perl
running the test rather than the one being asked. And `postfix check` warns on a
perfectly healthy system, so demanding empty output would have failed every
guest. Write the assertion, then ask what would make it fail, and what would
make it pass.

**Ask nginx, do not reason about nginx.** `systemctl restart nginx` failing tells
you nothing; the guest's `nginx -t` tells you exactly what is wrong. Three
recipes were blocked on one line — a socket in a `proxy_pass` inside
`location @default`, which nginx refuses because a named location may not carry
a URI part, while the socket form requires one. No amount of reading the
template would have produced that sentence. Keep a guest and ask it.

**A guest test that renders no assertions fails the build**, because Test::More
exits 255 on none. `t/recipes.t` renders all of them, compiles each, and checks
each asserts something -- run it after touching one, rather than finding out at
the end of a provision.

**A binary that is there is not a binary that runs.** `command -v node` answers
with a path whether or not the thing at the end of it can start, and the node
builds nvm downloads link against a library Ubuntu does not install -- so node
was present, unrunnable, and passing every check in its own test. Run the thing:
`--version` is enough, and it is the difference between checking a filename and
checking a program.

**Ask whether the test would notice.** Several here passed while the thing they
named was broken: `nvm` compared two empty strings, `matrix`'s chrony test ran
before the config it checks was applied, and asking `systemctl is-active nginx`
says nothing about a config file nginx has not read yet — `nginx -t` does.

## Two things about the harness

**Never edit a script while it is running.** bash reads a script incrementally,
by byte offset, so editing one mid-run resumes it somewhere meaningless. Editing
`run_one` while a sweep was using it killed the run that was in flight and left
an orphaned guest behind. Copy the harness to a new directory for the next batch
instead.

**Give the scratch guest a service user.** Every real domain sets one in its
`_global`, and several recipes only line up when it exists: the `service_user`
target gives that account the domain directory as its home, and
`build_latest_perl.sh` symlinks `cpanm` into that home -- which is exactly where
`tcms` and `tpsgi` look for it. Without one, the sweep falls back to the admin
user, whose home is under `/home`, and those paths disagree for reasons that
have nothing to do with the recipe.

**A dummy value that is no longer needed is worse than none.** `perl.user` was
pinned to `www-data` back when the field was required. It is filled in from the
service user now, so the dummy did nothing but override it -- and `/var/www`
does not exist on a guest with no web server, so the perl build stopped and
`imagemagick`, which builds against that perl, had nothing to build against.
Re-read the dummies when the schema they were written for changes.

**Do not edit templates while a sweep is provisioning either** — the run picks up
whatever is on disk when it generates its configuration, so a batch started
before a change and finished after it tells you nothing you can attribute.

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
