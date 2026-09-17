# General recipe guidelines

## Sockets

* When possible with HTTP services, we are to use unix sockets rather than publically accessible ones, and proxy access via nginx to these.
    - When the above is not possible, a recipe MUST add a UFW application configuration to /etc/ufw/applications.d so that it will be allowed to communicate.

## SSL

* When a service requires SSL to function, both the letsencrypt and pdns targets' templates will need to be considered and most likely updated so that DNS DCV for its subdomains can function properly.

## Makefile target execution order is not guaranteed

* When you need to restart services or interact with things which may or may not be present and functioning at the time your recipe's target runs, be sure to queue it as a postrun task.

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
