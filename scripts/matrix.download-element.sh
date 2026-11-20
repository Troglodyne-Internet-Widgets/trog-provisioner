#!/bin/bash
# Download and extract Element Web, the Matrix client.

# pipefail, because the download is the left half of a pipe and -e alone looks
# only at the exit status of tar.
set -eo pipefail

ELEMENT_DIR="$1"
if [ -z "$ELEMENT_DIR" ]; then
    echo "Usage: $0 <element-directory>"
    exit 1
fi

# The name of the release asset has the version in it, so releases/latest/download
# cannot name it.  A guest reaches github.com but not api.github.com, so the tag
# comes from the page of the latest release, which links to its own tag.  The
# page and not the redirect to it, because a fetch cache follows the redirect
# itself and hands back the page.
LATEST=https://github.com/element-hq/element-web/releases/latest
page=$(curl -fsSL "$LATEST")
if [[ ! "$page" =~ releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+) ]]; then
    echo "Could not tell the latest release of Element Web from $LATEST"
    exit 1
fi
tag="${BASH_REMATCH[1]}"

mkdir -p "$ELEMENT_DIR"
echo "Downloading Element Web $tag..."
if ! curl -fsSL "https://github.com/element-hq/element-web/releases/download/$tag/element-$tag.tar.gz" | tar -xz -C "$ELEMENT_DIR" --strip-components=1; then
    echo "Failed to download or extract Element Web $tag"
    exit 1
fi

echo "Element Web $tag downloaded to $ELEMENT_DIR"
