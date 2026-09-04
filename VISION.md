# Vision: or, why the hell do we need another 'nomad' or 'kubernetes'

These are big self-contained projects that do way too much.
They do not leverage the existing strengths of operating systems
to minimize the amount of code they need to write.

To make matters worse, because they do so much, their configuration format
and means to extend them are *more* complicated than "lol just make RPMs".

While there is an argument to be made for arrogating all under the purview
of the computer to your program (in an environment of uncertainty, vertical
integration is a winning strategy), this simply does not hold in the least
on modern linux systems.

Things like package managers and init systems have been around a long time,
are stable, *infinitely* better documented, well tested and most importantly
it's one less thing you have to do.

In many ways our approach with trog-provisioner leans heavily on this.
Cloud-init, Make and atd are nearly all of the 'secret sauce' that makes
this all work. (as an aside, cloud-init is reimplementing Make with a recipe bag-on-the-side,
e.g. much of what I'm doing here, but in python! why do we keep doing this to ourselves)

So, in that spirit, the long term goal of this project is to leverage existing
OS facilities to build the kind of auto-scaling control plane you want.

If it doesn't make me think "pootie done did it again" (search it on youtube) RE the simplicity
it's probably not good.

At the end of the day, what a contracting house needs is similar to how houses are built.
COTS, interchangeable parts so simple nearly anyone (or llm 'agent') can use it safely.
This way you can focus on actually important things, e.g. profitable capital allocation.

We have to have a process powerful enough that it enables us to:

* Be effective at being a microISV enough you have a shot at scaling without debt/equity issue
* Be effective as a 'hired gun' slanging for clients
* Be effective in corporate no matter how dysfunctional their existing process is

## What needs to change

1. We need to eliminate terraform usage in trog-provisioner entirely in favor of libvirt
XMLs & calls; that the terraform provider is not a meaningful reduction of complexity
when compared to XML is quite the indictment.  It's pretty much the same story with
all the other abstractions that make this work with podman/docker/snap/flatpack et al.
When the abstraction is more complex than doing the thing directly, you should instead
build a simple interface that has pluggability.  That's the whole approach of Provisioner::Recipe!

2. Right now we lean on make failing on any bad rc as our test/verification, optionally
having additional testing includable by recipes.  We need a strong policy and structure
that allows us to never have to do silly things like /bin/true at the end of lines that
undermines this.  Ultimately the only thing that will ensure such idempotency is a robust
test suite, which means we'll dogfood our own control plane here.

3. We can radically simplify the provision process via leaning on RPM/Deb.  We are already
building makefiles and setting up the HV as a deb mirror, may as well "make it a fish" and
just make the *entire* deploy process save data schlepping managed by clown-init's
"install-packages" recipe.  Provisioning the target need be as simple as adding $domain
to the list of needed packages, as it's a metapackage that brings in all the needed pkgs.
Thankfully, this won't be that hard because both of these are already makefile-pilled to
the max; we can then pawn off the actual package building to OBS!

4. We need to control individual VMs via systemctl files.
Reload rebuilds the VM, while start/stop does what you expect.
Implement healthchecks w/timers.

5. The actual control plane needs to be something like a preforking PSGI server
but that has the ability to scale up/down workers via the min\_spare\_servers mechanism
in Net::Server::PreFork.  Each 'request' does something with a VM, be it forwarding a req
or managing the VM itself.  These requests 'lock' the VM from being used by other workers
IFF it's a VM state change or said VM fails a health check.
After a grace period (or it has no known active jobs, but is still failing health)
we either unlock it for use or respawn it.

6. Control plane has to coexist with static infrastructure.  Not everything can or should autoscale.
It needs to know what guests are under it's control, and have strict quotas.

7. From there any frontend management interface is largely a recipes.d config builder,
and intermediator with the control plane.
It needs to treat everything it needs done as a queue of jobs that it polls for status,
optionally specifying what can be done in parallell at each step.
at / atq and each job being a makefile and having its own log largely handles this, but
perl w/ log::dispatch::db may make more sense.

## Good design principles to follow & things that fall out of that

0. Force the user to fall into good patterns.
Like weapons systems used by soliders, if you can be "holding it wrong", it's bad.

1. Data sources can't ever get out of sync. Like with RAID, this means you always need a replicated spare.
If you have one, you have none.  May as well make all recipes explicitly follow this pattern.
This way backup is stupid-simple.

2. Secrets should be protected.  This is why things like vault exist, but this is overkill versus keepassxc.
We need something like a bone-simple keepassxc server for secret management.
Maybe that's even overwrought versus simply encrypting data in a DB.
OpenSSL is good enough for the rest of the world, it's good enough for you.

3. chroot and unshare everything possible.  If you don't need it, get rid of it.
Don't open ports you don't need.  The firewall and fail2ban recipes need extreme scrutiny.
Testing these should be an integral part of deploys.

4. Actions that change anything at all thru web-accessible interfaces should generally happen with this workflow:
Plan of action presented -> User consents -> one-time token(s) to do thing issued -> thing done.
This makes things all very well auditable & minimizes shenanigans from agents & social engineering.

5. Ruthless focus on the Deming insights into the production process.
Any time we see outliers in provision time, defect rate, etc it needs to be easily identified and proactively notify

6. Long-running processes need to be able to notify you when something is ready in a low-noise, high signal channel.
This way you can go and do something else until things are ready.
Ideally we simply have an RSS feed we can subscribe to on a phone or other device to keep you on track.
Your OODA Loop has to be tight!

7. Don't ever forget that what makes LLMs work well with your projects is the same thing that makes working with other people easy.
Your documentation is far more important than the code, so do it first, and keep it up-to-date.
