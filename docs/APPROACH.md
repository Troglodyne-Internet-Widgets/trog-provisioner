# General recipe guidelines

## Sockets

* When possible with HTTP services, we are to use unix sockets rather than publically accessible ones, and proxy access via nginx to these.
    - When the above is not possible, a recipe MUST add a UFW application configuration to /etc/ufw/applications.d so that it will be allowed to communicate.

## SSL

* When a service requires SSL to function, both the letsencrypt and pdns targets' templates will need to be considered and most likely updated so that DNS DCV for its subdomains can function properly.

## Makefile target execution order is not guaranteed

* When you need to restart services or interact with things which may or may not be present and functioning at the time your recipe's target runs, be sure to queue it as a postrun task.

## Who owns the domain directory

Several recipes write into `[% install_dir %]/[% domain %]`, and the last `chown` to run wins.  So the owners are fixed here, and each recipe keeps to them.

* The domain directory belongs to `user:admin_user`.  The `service_user` target and the data recipe set that owner.  No other recipe changes the owner of the directory itself.
* A recipe that needs a different owner sets it on its own subdirectory only.  For example, admincode gives its `basedir` to the admin, and tpsgi gives `www` and `run` to the `www-data` group.
* Use `chown -R` only on a directory that the recipe made and owns.  A recipe that checks out into the domain directory itself chowns what it checked out, and not the domain directory.
* If another account must read the domain directory, change the mode and not the owner.  nginxproxy adds `o+x`, and nginxdirindex adds `o+rX` to everything that is not a dot entry.
* Give each recipe a guest test for the owners that it depends on.

## Waiting on things

* Don't ever use static sleeps unless inside of a polling loop which checks that what you are waiting on is actually ready.  It's fine to write a standalone script to do this when necessary.

## Dependencies

* Name what you depend on in `required_recipes` and let the depsolver do the rest.  It adds the recipe to the build when the domain did not ask for one itself, merges what every dependent asked of it into a single configuration, and puts it in `modules` -- so a recipe you require is a recipe that is present, and there is nothing to assert about that afterwards.  Requiring a dependency of a dependency is not the sin it was once written up as here: a recipe named twice is built once, with the contributions reconciled.
* **A dependency's target runs *after* the recipe that dragged it in**, not before -- the depsolver orders it below the last requester so that everything contributing to it has had its say.  So a fragment may not assume its dependency has already run: the accounts, directories and packages that dependency installs do not exist yet.  Make what you need yourself, own it as `root`, and defer anything that needs the other recipe's service to a postrun task.
* A guard in `enrich()` is for a recipe you depend on and deliberately do **not** require -- where pulling it in would do something unwanted rather than something helpful.  Standing a listener for the whole fleet up on a guest that only wanted its own logs kept would be that.  There, being handed the recipe and being on the right guest are different questions, and refusing is how a recipe says which one it means.
    - Example: `die "This recipe requires the nginxproxy recipe to function" unless List::Util::any { $_ eq 'nginxproxy' } @{$opts{modules}};`
    - **Not for a dependency you named yourself in `required_recipes`.**  That one is already there by the time anything renders, so the guard cannot fire.  No recipe here needs one today, and `grafanasyslog` carried such a guard until it was noticed that it could not.
* A required field of a recipe you require is still the operator's to supply, and `required_recipes` is where you supply it if you can.  What you cannot is a secret: `grafana` requires an `admin_password` with no default, so a domain configuring `grafanasyslog` configures `grafana` alongside it.  Note that `bin/new_guest` does not presently look through `required_recipes` for such fields, so it reports nothing to fill in and `bin/new_config` is what refuses.
* Never override `validate()`: it is the universal one, and a recipe that replaces it discards the schema it composes and its own `enrich()` with it.

## Secrets in a fragment

make prints each command before it runs it.  `ubuntu.setup.sh.tt` keeps that output in `/var/log/<domain>.setup.log` on the guest, and that log stays after the build.  The provisioning skill also copies it back to this machine.  So a secret on a command line is a secret in a log that more people and machines can read.

* If a command carries a secret, start it with `@`.  make does not print a command that starts with `@`.
* Put the `@` on the first line of the command.  On a line that continues a command, bash reads the `@` as part of a word, and the command fails.  A template directive such as `[% END -%]` is not a line of the command, so look above it.
* Keep the secret out of argv too, because `ps` shows argv to every user on the guest.  Write the secret with `printf` or `echo`, which are shell builtins, and give the program a file or stdin.
* Make the file with `install -m 0600 /dev/null <file>` before the secret goes into it, so that the file is never readable by other users.  After the command, remove the file.
* A secret that a service reads each time it starts goes in a file from `template_files` or `guest_secrets`, not in a command.  `templates/ubuntu/github.tt` writes its token that way.

The LDAP seed is the example:

```
install -m 0600 /dev/null ldap.admin_password
@printf '%s' '[% admin_password %]' > ldap.admin_password
@ldapadd -c -x -D "cn=admin,[% base_dn %]" -y ldap.admin_password -f seed.ldif || ...
rm -f seed.ldif ldap.admin_password
```

Use `@` in the same way on a command whose text names a failure, such as `|| echo "could not ..."`.  When make prints that command, the log shows the failure text on a run that worked.  A real failure still shows its message, because the `echo` runs and writes to stderr.

`t/recipes.t` enforces two of these rules.  It fails in two cases: a printed command holds the value of a field that names a secret, or an `@` is inside a command.  `Trog::Secrets->names_a_secret` decides which fields name a secret: a password, a secret, a token, a credential, a key, or a name that ends in `_pw`.  Give a new secret field a name like that, or the test cannot find it.
