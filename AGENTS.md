# AGENTS.md - Coding Guidelines for Provisioners Repository

This document provides guidelines for AI coding agents working with the Provisioners codebase.

## Overview

Provisioners is a Perl-based configuration file generator for provisioning VMs using a recipe-based approach.
It generates makefiles and configuration files to deploy services easily with backup/restore capabilities.
These are then to be used by the `trog-provisioner` project.

## Build and Test Commands

### Running the Main Tool
```bash
# Create a new configuration for a domain
bin/new_config test.somedomain

# With custom config files
bin/new_config --ipmap=path/to/ipmap.cfg --recipes=path/to/recipes.yaml domain.name
```

### Perl Module Development
```bash
# Install dependencies (if cpanfile exists)
cpanm --installdeps .

# Run perl syntax check, should say OK
perl -c lib/Provisioner/Recipe/yourmodule.pm

# Run it thru perlcritic, should get no output
perlcritic lib/Provisioner/Recipe/yourmodule.pm

# Check POD documentation has no POD errors
perldoc lib/Provisioner/Recipe/yourmodule.pm
```

### Testing
See t/TESTING.md

## Code Style Guidelines
See STYLE.md

### Recipe Development

#### Required Methods
```perl
sub deps {
    my ($self) = @_;
    if ($self->{target_packager} eq 'deb') {
        return qw{package1 package2};
    }
    die "Unsupported packager";
}

sub validate {
    my ($self, %opts) = @_;
    # Validate configuration options
    die "Required option missing" unless $opts{required_option};
    return %opts;
}
```

#### Optional Methods
```perl
sub template_files {
    return (
        'source.tt' => 'destination',
        'config.tt' => 'etc/config.conf',
    );
}

sub remote_files {
    return (
        '/remote/path/file' => 'local/backup/path',
    );
}
```

### Template Style (Text::Xslate TTerse)

- Use `[% %]` for template tags
- Variables: `[% variable_name %]`
- Loops: `[% FOR item IN list %]...[% END %]`
- Conditionals: `[% IF condition %]...[% END %]`
- Raw output: `[% var | mark_raw %]`

### Makefile Generation

Templates generate makefile fragments:
- No leading tabs (added automatically)
- Must be re-entrant for parallel execution

## File Organization

```
provisioners/
├── bin/              # Executable scripts
├── lib/              # Perl modules
│   └── Provisioner/
│       ├── Recipe.pm # Base class
│       └── Recipe/   # Recipe implementations
├── scripts/          # Helper scripts deployed to VMs
├── templates/        # Template files
│   ├── *.tt          # Main recipe templates (makefile target fragments)
│   └── files/        # Config file templates
├── docs/             # Documentation
├── vendor/           # Custom/private modules (gitignored)
├── recipes.yaml      # File that controls what recipes to load when provisioning any given guest (gitignored due to necessarily containing sensitive information)
└── ipmap.cfg         # File that describes the network topology of our guests and the admin user's information (gitignored due to necessarily containing sensitive information)
```

## Best Practices

1. **Data Persistence**: Use `remote_files()` for backup/restore functionality
2. **File Paths**: Use absolute paths in templates where possible. The `[% install_dir %]/[% domain %]` should be where the primary software to deploy on the guest lives, with supporting (public) services in subdomain folders under [% install_dir %].
3. **Permissions**: Set files/dirs to 0750 with `user:admin_user` ownership, substituting `user` with the relevant service user (e.g. www-data for nginx) where applicable.
4. **Symlinks**: Link configs from install_dir to system locations when feasible, this simplifies backup/restore operations.
5. **Dependencies**: List all package dependencies explicitly in `deps()`
6. **Validation**: Validate all required options in `validate()`, optionally augmenting them if needed.
7. **Documentation**: Include POD with SYNOPSIS showing yaml config example

## Common Patterns

### Service User Creation
```perl
# In template
[% IF user %]
useradd -s /usr/sbin/nologin -d [% install_dir %]/[% domain %] [% user %]
[% END %]
```

### Config File Deployment
```perl
# In recipe
sub template_files {
    return ('nginx.conf.tt' => 'nginx/sites-enabled/domain.conf');
}
```

Nearly all of the configuration of the software that a recipe provisions will be handled via one of these templates.
What remains ought done by:
    - a script that lives in the script dir (scripts/ in this repo, or `[% script_dir %]` when in templates).
    - a command in the makefile fragment template itself

## Recipe Guidelines (from docs/APPROACH.md)

### Networking and Security
- **Unix Sockets**: Use unix sockets for HTTP services when possible, proxy via nginx
- **UFW Rules**: If public sockets are needed, add UFW application config to `/etc/ufw/applications.d`
- **SSL**: Update letsencrypt and pdns templates for DNS DCV when service requires SSL

### Execution and Dependencies
- **Order Not Guaranteed**: Use `queue_postrun_task` for service restarts or dependent operations
- **No Static Sleeps**: Use polling loops to check readiness, never static sleep times
- **Recipe Dependencies**: Don't list packages from dependent recipes in `deps()`. Instead validate:
  ```perl
  die "This recipe requires the nginxproxy recipe"
      unless List::Util::any { $_ eq 'nginxproxy' } @{$opts{modules}};
  ```

## Debugging Tips

1. Check generated makefile in target directory
2. Verify template variables with debug output
3. Test recipes individually before combining
4. Use `make -n` to preview commands without execution
5. Check state files in `[% state_dir %]` for completion status
