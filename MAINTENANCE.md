# What is pinned here, and how to tell when it has gone stale

Everything below names a version, a commit, a URL or a package that somebody
chose on a particular day.  None of it is wrong; all of it ages.  This is the
list to walk when a build starts failing for no reason you changed, and the list
to walk once in a while so that it does not.

Ordered by how quietly it fails.

## It fails silently

**The lexicon patches.**  `templates/ubuntu/pdns.global.tt` applies two patches
to Ubuntu's `lexicon` package: `templates/files/patches/lexicon-pdns-af-unix.patch`
and `lexicon-arbitrary-record-types.patch`, both taken against the package as it
was in October 2025.

They no longer fail silently, and the way they used to is worth keeping in mind
for anything else written like it.  The line said `git apply ... ; /bin/true`,
so a second provision would not fail on an already-applied patch -- and the same
`/bin/true` swallowed *"there is no such file"*.  The path was wrong for the
whole life of the line (`/tmp` for a payload that untars into `/var/tmp`), so
the patches never applied on any guest, and `prefer_local_dns` could not have
issued a certificate.  Nothing said so until somebody read a dehydrated hook's
traceback.  It now skips only when `git apply --reverse --check` says the patch
is already in, and says so on stderr when a patch will neither apply nor
reverse.

*Stale when:* Ubuntu updates `lexicon`.  One of these went upstream, so the
af-unix one being *already applied* is the expected end state rather than a
fault, and the day it is, the patch can go.  *Check:* the build prints
`already applied` or `WOULD NOT APPLY` for each; and the pdns guest test asks
lexicon whether it can reach the socket, which is the thing actually needed.

**The matrix admin interface.**  `scripts/matrix.download-admin.sh` fetches
`releases/latest` from `etkecc/ketesa`.  That project has already been renamed
once -- it was `synapse-admin` -- and the old URL 404'd quietly, so the admin
interface was simply never installed.

*Stale when:* it is renamed again, or the asset stops being called
`ketesa.tar.gz`.  *Check:* the admin directory on a matrix guest is not empty.

## Commit pins

`lib/Provisioner/Recipe/perllsp.pm` pins four vim plugins to commits, fetched as
codeload tarballs by `templates/ubuntu/perllsp.tt`:

| plugin | repo |
|---|---|
| async | `prabirshrestha/async.vim` |
| vim-lsp | `prabirshrestha/vim-lsp` |
| asyncomplete.vim | `prabirshrestha/asyncomplete.vim` |
| asyncomplete-lsp.vim | `prabirshrestha/asyncomplete-lsp.vim` |

Commits rather than tags on purpose: two of the four have no tags at all, and
the other two's newest are from 2020 and 2021, hundreds of commits behind.  The
schema demands a full 40-character SHA, so bumping one means resolving it first.

*Stale when:* enough has changed upstream to be worth taking, which is a
judgement rather than an event.  *Check:* compare each pin against the repo's
default branch; a force-push or rename shows up as a 404 at build time.

## Versions this repository chooses

| what | where | why it is that number |
|---|---|---|
| garage fallback | `lib/Provisioner/Recipe/garage.pm`, `$FALLBACK_VERSION` | used when the tag lookup fails; must be a version that is actually published, or the guest 404s mid-build.  The same version is repeated in that file's POD and drifts separately |
| configd floor | `lib/Provisioner/Recipe/configd.pm` | 0.001 breaks multi-domain mail sender-login maps.  `scripts/install_configd` carries its own, older, default |
| nvm | `lib/Provisioner/Recipe/nvm.pm` | the installer is pinned; the node it then installs is not |
| pdns train | `lib/Provisioner/Recipe/pdns.pm`, `repo_branch` | `auth-51`: unix-socket `webserver-address` needs 5.0 or newer, and `auth-master` once shipped an alpha |
| mariadb | `lib/Provisioner/Recipe/mariadb.pm` | required, exact, no fallback: an approximate version restores no binlogs.  Which releases have a noble repo is written down in two places |
| imagemagick | `lib/Provisioner/Recipe/imagemagick.pm` | required, with the patch number; the archive prunes old releases |
| gogs | `lib/Provisioner/Recipe/gogs.pm` | required; the asset spelling changed at 0.14.2, which is why the template tries two names |
| roundcube | `lib/Provisioner/Recipe/roundcube.pm` | required; this one gets security releases worth following |
| step-ca | `lib/Provisioner/Recipe/acmeca.pm`, `$STEP_CA_VERSION` | required; the release tarball is fetched from GitHub by version, so one that was never published is a 404 partway through a provision.  The recipe finds the binary inside the tarball rather than naming its directory, so a layout change upstream does not need a bump |
| perl | `scripts/build_latest_perl.sh` | `perlbrew download stable`, so whatever is stable on the day.  Its three modules -- cpanm, Module::Build, Dist::Zilla -- are unversioned for the same reason |

*Check:* each project's release page.  For garage, `bin/recipes garage` shows
what the lookup answers today.

## Deliberately not pinned

matrix/synapse and plex install from their own apt repositories; ketesa and
`nvm install node` take whatever is newest; the claude plugin marketplaces are
three GitHub repositories named by path.  Each of these is a build that can
change without this repository changing.

## The base image

`Provisioner::Recipe::ubuntu::release` names the release, and everything else is
derived from it.  It is pinned on purpose -- a release moves and a fleet does
not have to move with it -- and `bin/preflight` *notes* when the pin is behind
what Ubuntu currently calls current, rather than failing.  Note the image URL
contains `/current/`, so its contents move under a fixed name: two guests built
months apart from the same pin are not the same guest.

## Checked rather than pinned

`Sys::Virt` has to match the hypervisor's libvirt, and `bin/preflight` compares
them and says what to install when they disagree.  On a runner, trogrunner asks
the guest's own `pkg-config` at build time rather than writing a version down.
Nothing here goes stale; it is listed so nobody "fixes" it by adding a pin.

## Package names and apt sources

- **`t64` suffixes** -- `libapr1t64`, `libaprutil1t64`, `libtcmalloc-minimal4t64`
  in the roundcube and imagemagick deps: an Ubuntu 24.04-era naming from the
  64-bit `time_t` transition, which will not outlive it.
- **`libolm`** (koan) is deprecated upstream and has been dropped by some
  distributions.
- **`cronie`** (cron) is unusual on Ubuntu, where the package is normally `cron`.
- **`apt-key`** is deprecated and removed in current releases, and
  `templates/ubuntu/pdns.global.tt` is the last place using it -- with two short
  key IDs and no fingerprint recorded anywhere.  Everything else uses
  `signed-by=` keyrings.
- Signing keys are fetched at build time and trusted on receipt: matrix, plex,
  mariadb, powerdns.  Plex's key has already moved once, and the old one is dead.

*Check:* a failed build says the package name; the key ones only bite when a
repository rotates.

## Numbers somebody measured

`Provisioner::Recipe::aptmirror` carries the size of a noble mirror per
component, and its `require_free_gb` is calibrated against the `vm` recipe's
default disk so that a mirror left on that default fails immediately rather than
halfway through.  Both grow over a release's life, and the second stops working
as a sentinel if the first default changes.

## Prose that repeats a version

Three places state a version in text as well as in code, and the text drifts on
its own: garage's POD, the note in the mariadb recipe and `install_mariadb.sh`
about which releases have a noble repository, and that script's remark about
which version Ubuntu ships.
