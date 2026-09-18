#!/bin/bash
# Download and extract ketesa, the Synapse admin interface.

# pipefail, because the download is the left half of a pipe and -e alone looks
# only at the exit status of tar.
set -eo pipefail

ADMIN_DIR="$1"
if [ -z "$ADMIN_DIR" ]; then
    echo "Usage: $0 <admin-directory>"
    exit 1
fi

mkdir -p "$ADMIN_DIR"

# ketesa is the current name of synapse-admin.
echo "Downloading ketesa (synapse-admin)..."
if ! wget -O - https://github.com/etkecc/ketesa/releases/latest/download/ketesa.tar.gz | tar -xz -C "$ADMIN_DIR" --strip-components=1; then
    echo "Failed to download or extract ketesa"
    exit 1
fi

echo "ketesa downloaded successfully to $ADMIN_DIR"
