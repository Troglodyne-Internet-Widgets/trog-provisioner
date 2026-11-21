# General recipe guidelines

## Sockets

* When possible with HTTP services, we are to use unix sockets rather than publically accessible ones, and proxy access via nginx to these.
    - When the above is not possible, a recipe MUST add a UFW application configuration to /etc/ufw/applications.d so that it will be allowed to communicate.

## SSL

* When a service requires SSL to function, both the letsencrypt and pdns targets' templates will need to be considered and most likely updated so that DNS DCV for its subdomains can function properly.

## Makefile target execution order is not guaranteed

* When you need to restart services or interact with things which may or may not be present and functioning at the time your recipe's target runs, be sure to queue it as a postrun task.
* The guest runs `make -j`, so a recipe runs at the same time as every recipe that it has no dependency with.  The dependencies come from `required_recipes`: a recipe runs after each recipe that requires it.  If your fragment needs what another recipe installs, name that recipe in `required_recipes`.  Its position in the list of a domain orders nothing.
* The postrun queue runs in the serial order of the targets, whatever order they finished in.  So the order of the tasks within your recipe, and across recipes, is the same as before `-j`.  In that order a dependency's tasks run after those of the recipes that required it, because its target does.  A task that needs another recipe's task done first cannot count on the other recipe coming first unless that recipe requires this one.

## Who owns the domain directory

Several recipes write into `[% install_dir %]/[% domain %]`, and the last `chown` to run wins.  So the owners are fixed here, and each recipe keeps to them.

* The domain directory belongs to `user:admin_user`.  The `service_user` target and the data recipe set that owner.  No other recipe changes the owner of the directory itself.
* A recipe that needs a different owner sets it on its own subdirectory only.  For example, admincode gives its `basedir` to the admin, and tpsgi gives `www` and `run` to the `www-data` group.
* Use `chown -R` only on a directory that the recipe made and owns.  A recipe that checks out into the domain directory itself chowns what it checked out, and not the domain directory.
* If another account must read the domain directory, change the mode and not the owner.  nginxproxy adds `o+x`, and nginxdirindex adds `o+rX` to everything that is not a dot entry.
* Give each recipe a guest test for the owners that it depends on.

## Several domains on one machine

A domain can run on the guest of another domain.  The other domain is its host, and the domain is a tenant.  `Provisioner::Cookbook` has `host_of`, which names the host of a tenant, and `machine_of`, which names the domain whose guest runs a domain.  A recipe says how it behaves on a shared machine with the facilities below.  Each one answers a different question.

| Facility | The question that it answers | Default |
|---|---|---|
| per-domain fragment, `<name>.tt` | What does the recipe do for one domain? | |
| global half, `<name>.global.tt` | What does the machine need once, however many domains it holds? | none |
| `is_multi_tenant` | Can two domains on one machine both have the recipe? | true |
| `machine_wide` | Which settings must a tenant leave as its host has them? | none |
| `exclusive_with`, `exclusive_on_machine_with` | Which other recipe collides with this one, on one domain or on one machine? | none |

`perldoc Provisioner::Recipe` has the contract of each.  This section says why each one exists and when to use it.

### The per-domain fragment

The fragment runs once for each domain that names the recipe.  It writes what belongs to that domain: files under `install_dir`, a vhost, a fragment in a `conf.d`.  A recipe that does all of its work here serves any number of domains, and needs none of the other facilities.  So put the work here when you can.

### The global half

The global half runs once on the machine.  The makefile records it in `/etc/provisioner/state/global_<name>`, and every later build on the machine skips it.  A tenant builds on a guest that its host already built, so the global half usually runs with the configuration of the host.

Put here what the machine has one of: a package, a service with one configuration file, a firewall profile.  If the service reads one file and has no `conf.d`, look at `Provisioner::Recipe::configd` first.  It gives the file a fragment directory, so each domain can write its own part from the per-domain fragment.

For a tenant, the global half does nothing.  This is how most services of the machine are shared.  `_base` names the recipe, every tenant inherits it, and only the build of the host does the work.

### is_multi_tenant

Make it false only when two domains cannot both have the recipe.  One synapse has one `server_name`, so a second domain would replace the first.  `bin/new_config` then refuses the recipe for a tenant that is layered onto a host that has it.

A global half alone is not a reason to make it false.  The refusal also stops `_base` from naming the recipe, because every tenant inherits `_base`.  logshipper was false for that reason, and so `_base` could not name it.  If the only problem is a tenant that asks for other settings, use `machine_wide`.

### machine_wide

The global half takes its settings from the configuration of one domain, usually the host.  A tenant whose settings differ gets those of the host, and the build ignores its own.  That was always so.  `machine_wide` changes only one thing: a difference now stops the build, where before it was ignored.

The case for this rests on one question: is it better to die or to ignore?  It is better to die, because of a core goal of this software.  A hosting package must be fungible, which means that it can move between hosts and hypervisors and get the same result.  A tenant whose logshipper settings are ignored ships its logs to the collector of its host.  Move it to a machine of its own, and the same configuration ships them somewhere else.  Its configuration then does not say what the domain gets.  So if a domain cannot get the logshipper that it is configured with, its build must die.

`machine_wide` names the settings that the global half applies to the whole machine.  `bin/new_config` refuses a tenant whose values for them differ from those of its host, and names each setting with both values.  A tenant that inherits the same values from `_base` passes.

Name a setting here when the global half writes it into something that the machine has one of.  logshipper names all six of its settings, because each one goes into the one forwarder file of rsyslog.  ossecagent names `manager`, because the one agent of the machine sends to one manager.  A recipe that is not `is_multi_tenant` needs none, because its tenant is refused anyway.

### Work outside the makefile

The global half covers only what the makefile does on the guest.  `bin/provision` and `bin/destroy` do other work for each domain, from the configuration, and the global half does not reach it:

* `bin/provision` asks another guest for each of the `grants` of a domain before the build.
* `bin/destroy` revokes each of them when the domain goes away.

So a recipe whose service belongs to the machine decides in `grants` which domain holds the grant.  The agent of ossecagent has one key for the machine.  Its `grants` returns nothing unless the domain is its own machine.  Otherwise the build of a tenant would ask for a second key, and the teardown of a tenant would revoke the key that every domain on the machine uses.

### Collisions

`exclusive_with` names a recipe that cannot be on one domain with this one, because both write the same thing, such as the vhost of the domain.  `exclusive_on_machine_with` names a recipe that cannot be on one machine with this one, because both own something of the machine, such as port 25.  The second one is checked between a tenant and its host as well.

## State that survives a rebuild

A guest is rebuilt, not repaired.  A domain also moves to another host or hypervisor by a rebuild, and its configuration must give the same result there.  So everything a guest needs is either in the configuration, in the secret store, or in the salvage.  The salvage is what `bin/new_config` fetches from the running guest before a rebuild, and puts back when the guest is built again.  If you run `bin/new_config` from cron and keep what it fetches, the salvage is also a backup.  See [BACKUPS.md](BACKUPS.md).

Salvage the state that the guest made and that nothing can make again.  Ask what a person, or another guest, must do again after a rebuild.  If the answer is anything, the recipe must keep it.

* Salvage data that the service wrote: a database dump, a spool, keys that somebody accepted.
* Salvage what this guest issued to other guests.  Those guests are not rebuilt with it, so nothing issues it again.  The registrations and the ban keys of a relay are this kind, and so is the `client.keys` of an OSSEC manager.
* Salvage the state in force that another guest sent once.  The bans of a relay are this kind: a guest sends a ban only when it bans, so a relay that loses its bans lets the address back in.
* Do not salvage what another guest issued to this one.  That is a grant, and `bin/provision` asks for it again before each build.  See `grants` in `perldoc Provisioner::Recipe`.
* Do not salvage what the configuration or the recipe makes, such as a configuration file.  The build makes it again, so the salvage only carries it to the data directory and back.
* A secret that must stay the same across a rebuild, such as a host key that other guests pin, goes in the secret store through `guest_secrets`, not in the salvage.  The salvage can end up in an archive.

How a recipe does it:

* `remote_files` names each directory to fetch.  Each path is a directory, because the fetch copies a directory tree.  To keep one file, copy it into a directory of its own in `remote_prepare`, and salvage that directory.  `Provisioner::Recipe::ossec` does this with `client.keys`.
* `remote_prepare` runs on the guest just before the fetch.  Use it when the state on disk can be older than the state in force: dump the database, or save a set that lives in memory.  A command that fails gives a warning, and the older copy comes down.
* `restores` puts the salvage back where the service reads it, if that is not under `install_dir`.  The `data` target does it before every other target, and does nothing where the destination already holds state.  Keep state under `install_dir` when the software allows it, and no `restores` is needed.
* `remote_skip` keeps a part of a salvaged directory on the guest, when that part must stay on the machine that made it.

`perldoc Provisioner::Recipe` has the contract of each method.

## Waiting on things

* Don't ever use static sleeps unless inside of a polling loop which checks that what you are waiting on is actually ready.  It's fine to write a standalone script to do this when necessary.

## Dependencies

* Name what you depend on in `required_recipes` and let the depsolver do the rest.  It adds the recipe to the build when the domain did not ask for one itself, merges what every dependent asked of it into a single configuration, and puts it in `modules` -- so a recipe you require is a recipe that is present, and there is nothing to assert about that afterwards.  Requiring a dependency of a dependency is not the sin it was once written up as here: a recipe named twice is built once, with the contributions reconciled.
* **A dependency's target runs *after* the recipe that dragged it in**, not before -- the depsolver orders it below the last requester so that everything contributing to it has had its say.  So a fragment may not assume its dependency has already run: the accounts, directories and packages that dependency installs do not exist yet.  Make what you need yourself, own it as `root`, and defer anything that needs the other recipe's service to a postrun task.
* A package from a vendor archive goes in `deps()` like any other, and the archive goes in `package_sources()` beside it, in the subclass for the distribution.  The packager of the distribution, which `perldoc Provisioner::Packager` describes, gives first boot the archive and its key, and cloud-init then installs every package, through the fetch cache when there is one.  So a fragment does not add an archive, fetch a key, or update the package lists for one.  An answer that a package needs at install goes in `package_answers()`, and a package that must not be installed goes in `dep_conflicts()`, which the packager keeps out.  A source is in the terms of the packager: `perldoc Provisioner::Packager::Deb` says what an apt archive holds.  A fragment installs or removes a package only when a list cannot say it: nosnap purges a package that the image ships, and claude installs a `.deb` that no archive has.
* A guard in `enrich()` is for a recipe you depend on and deliberately do **not** require -- where pulling it in would do something unwanted rather than something helpful.  Standing a listener for the whole fleet up on a guest that only wanted its own logs kept would be that.  There, being handed the recipe and being on the right guest are different questions, and refusing is how a recipe says which one it means.
    - Example: `die "This recipe requires the nginxproxy recipe to function" unless List::Util::any { $_ eq 'nginxproxy' } @{$opts{modules}};`
    - **Not for a dependency you named yourself in `required_recipes`.**  That one is already there by the time anything renders, so the guard cannot fire.  No recipe here needs one today, and `grafanasyslog` carried such a guard until it was noticed that it could not.
* A required field of a recipe you require is still the operator's to supply, and `required_recipes` is where you supply it if you can.  What you cannot is a secret: `grafana` requires an `admin_password` with no default, so a domain configuring `grafanasyslog` configures `grafana` alongside it.  Note that `bin/new_guest` does not presently look through `required_recipes` for such fields, so it reports nothing to fill in and `bin/new_config` is what refuses.
* Never override `validate()`: it is the universal one, and a recipe that replaces it discards the schema it composes and its own `enrich()` with it.

## A setting that names another guest

A field whose value can be the name of another guest decides where the guest can be built.  `named_guests` in `Provisioner::Cookbook` reads every setting of a domain, and a value that is a domain of the installation names that guest.  `bin/new_config` then places the guest only on a hypervisor whose `network` reaches each guest that it names.  The rules are in "Networks" in [CONFIGURATION.md](CONFIGURATION.md#networks).  This applies to a recipe that `_base` names as well, so a field such as `logshipper.host` limits every guest of the installation.

* Mark a field whose value has the name of a domain but is not a guest, such as a DNS zone, with `'x-not-guest' => 1`.  Otherwise it ties the guest to the network of that domain.
* `'x-weak' => 1` does not free the guest from that network.  Weak says that the build can go on without the named guest, not that the guest reaches it from anywhere.
* A recipe that brings the guest onto the network of another guest, such as a VPN client onto the network of its server, names that guest in `joins_network_of`.  The guests on that network then do not limit where the guest goes.  `openvpnclient` is the example.
* Send to the address that the ip pool gives the named guest, not to a name that can resolve elsewhere.  `Provisioner::Utils::fleet_address` gives it from `ipmap`, as logshipper does.  If the named guest can be a VPN client, use `Provisioner::IPPool::reachable_address`, which gives its address in the tunnel, as mail does for its relay.  A VPN client reaches the addresses of the pool through the routes that its server pushes.

## Secrets in a fragment

make prints each command before it runs it.  `ubuntu.setup.sh.tt` keeps that output in `/var/log/<domain>.setup.log` on the guest, and that log stays after the build.  The provisioning skill also copies it back to this machine.  So a secret on a command line is a secret in a log that more people and machines can read.

* `bin/new_config` keeps secrets out of that log for you.  It knows each value that a `secret:` reference resolved to, and each value in a field that the schema of its recipe marks `'x-secret' => 1`.  In every fragment it renders, `Provisioner::Recipe->quiet_secrets` starts each command that holds one of those values with `@`, and make does not print a command that starts with `@`.
* So mark every field of `args()` that takes a password, a token or a key.  `t/recipes.t` refuses a field named like one that is not marked.  The mark also lets `bin/preflight` report a secret written into the configuration in the clear, where the store could hold it.
* A guest test is not quieted.  Test::More prints what a failed `like` or `is` compared, so compare a secret with `eq` inside `ok`.
* Keep the secret out of argv as well, because `ps` shows argv to every user on the guest.  Write the secret with `printf` or `echo`, which are shell builtins, and give the program a file or stdin.
* Make the file with `install -m 0600 /dev/null <file>` before the secret goes into it, so that the file is never readable by other users.  After the command, remove the file.
* A secret that a service reads each time it starts goes in a file from `template_files` or `guest_secrets`, not in a command.  `templates/ubuntu/github.tt` writes its token that way.

The LDAP seed is the example.  `bin/new_config` adds the `@` to the `printf`.  The `@` on `ldapadd` is there for the failure text, as the next paragraph says.

```
install -m 0600 /dev/null ldap.admin_password
printf '%s' '[% admin_password %]' > ldap.admin_password
@ldapadd -c -x -D "cn=admin,[% base_dn %]" -y ldap.admin_password -f seed.ldif || ...
rm -f seed.ldif ldap.admin_password
```

Start a command with `@` yourself if its text names a failure, such as `|| echo "could not ..."`.  When make prints that command, the log shows the failure text on a run that worked.  A real failure still shows its message, because the `echo` runs and writes to stderr.  Put the `@` on the first line of the command.  On a line that continues a command, bash reads the `@` as part of a word, and the command fails.  A template directive such as `[% END -%]` is not a line of the command, so look above it.

`t/recipes.t` checks both.  It renders each recipe that takes a secret with a `secret:` reference, resolves the reference through `Trog::Secrets` and a fake store, and passes the fragment through `quiet_secrets` as `bin/new_config` does.  It fails if a printed command still holds a value from the store, or if an `@` is inside a command.  If a recipe takes a new secret, add its reference to `%WITH_SECRETS` in the test, and add its value to `%STORE`.

## Where to build a scratch guest

Build a scratch guest on a libvirt hypervisor.  A libvirt guest costs nothing and comes up in minutes, so it is the right place to develop and test a recipe.

* A recipe does the same work on every hypervisor.  Its fragment runs in the makefile, and its files arrive in the payload.  A cloud guest gets the same makefile and the same payload as a libvirt guest.
* If a change touches that delivery, build it on a cloud as well.  The delivery is the makefile template, the payload, `ubuntu.setup.sh.tt`, cloud-init, and the hypervisor backends under `lib/Trog/HV/`.
* Name the libvirt hypervisor with `--hypervisor` on `bin/new_config` and `bin/provision`.  A cloud block in `hypervisors.conf` can hold its token as a `secret:` reference, and a scratch configuration has no value for it.  Without `--hypervisor`, the generator asks every hypervisor whether it has the domain, and it stops at that token.
