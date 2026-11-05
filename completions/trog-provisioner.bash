# Bash completion of the domain for bin/new_config, bin/provision and
# bin/destroy.
#
# Load it in ~/.bashrc:
#
#     source /path/to/trog-provisioner/completions/trog-provisioner.bash
#
# The domains come from bin/domains, beside the command that you complete, so
# a checkout completes from its own code.  That command reads the
# configuration as the three commands do, and honors TROG_PROVISIONER_CONFIG.
# If the line already has --recipes FILE, the domains come from that file.

_trog_provisioner_domains() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local prev=${COMP_WORDS[COMP_CWORD - 1]}
    COMPREPLY=()

    # Bash splits --recipes=FILE into three words at the "=".
    if [[ $prev == = && $COMP_CWORD -ge 2 ]]; then
        prev=${COMP_WORDS[COMP_CWORD - 2]}
    fi
    if [[ $prev == --recipes ]]; then
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
        return 0
    fi
    [[ $cur == -* ]] && return 0

    local cmd
    cmd=$(type -P -- "${COMP_WORDS[0]}") || return 0

    local -a recipes=()
    local i value
    for ((i = 1; i < COMP_CWORD; i++)); do
        [[ ${COMP_WORDS[i]} == --recipes ]] || continue
        value=${COMP_WORDS[i + 1]}
        [[ $value == = ]] && value=${COMP_WORDS[i + 2]}
        recipes=(--recipes "${value/#\~/$HOME}")
    done

    local domains
    domains=$("${cmd%/*}/domains" "${recipes[@]}" 2>/dev/null) || return 0
    mapfile -t COMPREPLY < <(compgen -W "$domains" -- "$cur")
    return 0
}

complete -F _trog_provisioner_domains new_config provision destroy
