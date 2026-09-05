#!/bin/bash
# Download and extract Synapse Admin

# pipefail as well as -e: the download is the left half of a pipe, and without
# it only tar's exit status is looked at.
set -eo pipefail

ADMIN_DIR="$1"
if [ -z "$ADMIN_DIR" ]; then
    echo "Usage: $0 <admin-directory>"
    exit 1
fi

mkdir -p "$ADMIN_DIR"

# ketesa, which is what synapse-admin was renamed to.  etkecc/synapse-admin
# redirects to etkecc/ketesa and the asset went with it, so the old URL --
# .../synapse-admin/releases/latest/download/synapse-admin.tar.gz -- is a 404
# and the admin interface was never installed.
echo "Downloading ketesa (synapse-admin)..."
if ! wget -O - https://github.com/etkecc/ketesa/releases/latest/download/ketesa.tar.gz | tar -xz -C "$ADMIN_DIR" --strip-components=1; then
    echo "Failed to download or extract ketesa"
    exit 1
fi

echo "ketesa downloaded successfully to $ADMIN_DIR"
