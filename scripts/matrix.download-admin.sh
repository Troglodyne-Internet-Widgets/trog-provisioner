#!/bin/bash
# Download and extract Synapse Admin

set -e

ADMIN_DIR="$1"
if [ -z "$ADMIN_DIR" ]; then
    echo "Usage: $0 <admin-directory>"
    exit 1
fi

mkdir -p "$ADMIN_DIR"

# Download with error handling
echo "Downloading Synapse Admin..."
if ! wget -O - https://github.com/etkecc/synapse-admin/releases/latest/download/synapse-admin.tar.gz | tar -xz -C "$ADMIN_DIR" --strip-components=1; then
    echo "Failed to download or extract Synapse Admin"
    exit 1
fi

echo "Synapse Admin downloaded successfully to $ADMIN_DIR"
