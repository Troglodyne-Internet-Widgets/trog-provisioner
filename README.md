# Provisioners

Configuration file generator to provision VMs w/ trog-provisioner

A 'pick what you want' recipe based approach

The idea is with a couple of config files you can deploy all your clients' easily
and burn it down / restore from backup ez.

```
bin/new_config test.somedomain
```

## ipmap.cfg

Relies on an ipmap.cfg to grab static IPs for VMs, and other relevant information.

Example:

```
[global]
tld=test.test
basedir=/opt/provisioners
admin_user=test
admin_key=gh:test
admin_gecos=Testy Testerson
admin_email=test@test.test
[ips]
tickle=192.168.1.1
hug=...
[aliases]
tickle=chase, kiss
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
```

Suppose we execute `bin/new_config tickle`.

The above would produce a VM config for tickle.test.test at 192.168.1.1, and place it in /opt/provisioners/tickle.test.test.

It would populate the default users.yaml to make the 'test' user, give them admin rights and ssh-import-id their github key.
You can augment this users.yaml by having one in the datadir specified in the `data` section of recipes.yaml below.

It would also set up vhost aliases & CNAMEs for the aliases, should you pick the relevant recipes.

TODO: support raw keys.

## Domains which are not subdomains of the TLD

Leave tld= blank, or do not set it in the event you wish to specify things by FQDN rather than subdomains.
This is useful when you have many sites to host on various domains.

Alternatively, setup CNAMES and use subdomains as normal.

## recipes.yaml

These will have sections describing user-configuration for the various recipes used by the subdomains defined in the IP map.
This file is gitignored in this repo, as it is necessarily super-secret information.
TODO: support fetching this via non plaintext means, e.g. vault or keepass.

Here's an example:

```
---
tickle:
    _global:
        user: my_service_user
        registrar:
            type: "cloudflare"
            user: "someGuy"
            key:  "FooBarBaz1"
        size: disk_size_in_bytes
        memory: ram_size_in_mb
        cpus:  num_cpus
    data:
        from: /opt/client-data
        to:   /opt/domains
    adminconfig:
        pkgs:
            - vim
            - tig
            - tmux
            - plocate
        skel: "/opt/dotfiles/test"
    nosnap:
    nostubresolver:
    perl:
    tpsgi:
    fail2ban:
    auditd:
    letsencrypt:
    ufw:
        port_forwards:
            - from: 25
              to: 2500
    cron:
        from: "cron"
        root_scripts:
            - cmd: "do_some_other_thing"
              interval: "*/5 * * * *"
              mailto: "foo@bar.baz"
        user_scripts:
            - cmd: "do_some_thing_in_PATH.sh"
              interval: "*/5 * * * *"
    perl:
    nginxproxy:
        proxy_uri: http://localhost:5000
    pdns:
        soa: "ns1.test.test"
        extra_records: "/opt/data/tickle.test.test/dns/zonefile"
    mail:
        names:
            test:
                gecos: "Testy Testerson"
                password: "@Test_123!"
        mail_aliases:
            - from: "test"
              to: "testy"
...
```
See EXAMPLE.md for more.

These are powered by subclasses of `Provisioner::Recipe`, say `Provisioner::Recipe::perl`.
All these subclasses MUST be lowercase on their least component.
This is so we can have special uppercase targets in the makefile you can't overwrite.

Feel free to check out their respective POD to understand how to configure them and what they do.

These modules render the appropriately named template in templates, e.g. `templates/perl.tt`.
These are makefile fragments with no leading tab (we add this for you).

All recipe makefile fragments must be re-entrant so we can run `make -j $whatever`.
This means you have to provide a list of deps up-front which can be run before everything else.

Similarly, there is a distinction between "global" and "per-domain" parts of recipes.
Global parts will only ever be run once on the host, no matter how many domains are provisioned
into the guest (see the 'Shared Hosting' section below).

Some recipes (like mail and a few others) aren't fully idempotent via the above mechanism.
This is because the software they provision does not have a 'config.d' scheme
which allows for providing shared configs without having to munge config files.
TODO - make a config.d service which can automunge for services that don't support said schemes.

## Global Data

Variables in the \_global section for a domain are available to all modules' templates.

The 'user' variable is special in that it is setup as a nologin service user for your app to do its operations with.
All modules should setup ownership of files & dirs to be 0750 user:admin\_user where applicable.

The idea in general is that all relevant files for your app should live within the to/ dir (for ease of backup/restore).
Modules MUST symlink to somewhere within when placing configs for various software about.
Anytime a filepath is specified in module makefile templates be sure to prepend the `install_dir` as that is where it will live.

## Domain specific data

The `data` module will make available all the contents of the `from` directory subdir named with the relevant domain on the Hypervisor running `trog-provisioner` into the newly created guest's `to` folder as a subdir named with the relevant domain.
The place these files live is made available to templates as the `data_dir` directory.

In the example above, that would mean /opt/client-data/tickle.test.test on the HV would be rsync'd to the guest at /opt/domains/tickle.test.test.

## Module specific information

See the README.MD or the perldoc for the various modules themselves on usage.

## Order of execution

The 'data' module is executed before all others, and then we use a lexical sort.
If you want a particular target to run before others, assign it an 'order' in its block in `recipes.yaml`:

    some_recipe:
        order: 0

In general it's best to only rely on sorting for pretty global stuff, like fixing broken-out-of-the-box networking (such is the fashion these days).

Otherwise, use `[% script\_dir %]/queue_postrun_task` to ensure the stuff from other targets you need are present.

## Shared configuration

You can have a special top-level item of the configuration `_base` to specify recipes which you want present in all hosts.
We will merge it under the domain's config (what you specify in `_base` will be overwritten where applicable).

## Shared Hosting

If you want to instruct trog-provisioner to (attempt) to use an already existing machine, use the `_shared` top-level item to note which can share VMs.

Example:

```
---
\_global:
    ...
\_shared:
    my.shared.host:
        - my.client.on.shared.host
        - ...
my.shared.host:
my.client.on.shared.host:
    ...
```

Supposing no VM exists, the config from `_global`, and `my.shared.host` would be built.
We would then immediately build the config from `_global` and `my.client.on.shared.host`, and instruct trog-provisioner it depends on the former.

When running trog-provisioner, it will then apply both configs, waiting until the first has reported success.

# Writing Modules

## scripts/

To simplify matters, we SCP over the scripts/ directory, which you should shove any complicated scripting into.
Be that used for recipes, or what have you.

# Generated files

When your recipe generates things like configs, stick the templates in templates/files.
Then identify them by name in the template\_files() method.

# Salvaged files

If you want to grab something from a dir on an existing provisioned host, describe them in the remote\_files() method.
This will stuff them in the specified location of the datadir.

It is straightforward to implement a backup strategy for your hosts using this mechanism, cron-ing new\_config, tarring up the results and shipping it.

## Modules you don't intend to publish

Feel free to make a vendor/ dir herein, it is gitignored.  Then use the 'libdir' parameter in your domain's configuration to search 'vendor'.
See the documentation in bin/new\_config for more information.

## Testing

See [TESTING.md](t/TESTING.md).

If there are tests you want run on guests after the provisioning process is complete,
you can make templated tests in templates/tests which will be run subsequent to provisioning.
