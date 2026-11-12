#!/bin/bash

# Builds the tag of loccount that it is given into /usr/local/bin/loccount,
# with the Go that Provisioner::Recipe::go installs.  The loccount recipe
# queues it as a postrun task, because nothing orders the go target first.

# Stop at the first failure, so that the error names the step that failed.
set -euo pipefail

VERSION=${1:-}
[ -n "$VERSION" ] || { echo "build_loccount.sh: no version given" >&2; exit 2; }

if [ "$(/usr/local/bin/loccount -V 2>/dev/null)" = "loccount $VERSION" ]; then
    echo "loccount $VERSION is already built"
    exit 0
fi

[ -x /usr/local/go/bin/go ] || {
    echo "build_loccount.sh: /usr/local/go/bin/go is not there; the go recipe has to run first" >&2
    exit 2
}

WORK=$(mktemp -d)
# go makes its module cache read-only, so the tree is made writable first.
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT

# atd starts the postrun without a HOME, and go keeps its caches under it.
# GOTOOLCHAIN=local, so that a go.mod that asks for a newer Go fails, rather
# than fetching a toolchain that nobody checked.  No telemetry, which go
# would otherwise write under HOME while the trap removes it.
export HOME="$WORK/home" PATH="/usr/local/go/bin:$PATH" GOTOOLCHAIN=local GOTELEMETRY=off
export GOCACHE="$HOME/cache" GOPATH="$HOME/gopath"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$VERSION" https://gitlab.com/esr/loccount.git "$WORK/src"
make -C "$WORK/src" loccount
install -o root -g root -m 0755 "$WORK/src/loccount" /usr/local/bin/loccount
/usr/local/bin/loccount -V
