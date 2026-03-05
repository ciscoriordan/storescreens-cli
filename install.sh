#!/bin/sh
set -e

REPO="storescreens/storescreens-cli"
INSTALL_DIR="/usr/local/bin"

# Get latest release tag
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$TAG" ]; then
  echo "Error: could not determine latest release."
  exit 1
fi

URL="https://github.com/$REPO/releases/download/$TAG/storescreens-$TAG-macos.tar.gz"

echo "Installing storescreens $TAG..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -fsSL "$URL" | tar xz -C "$TMPDIR"
install -m 755 "$TMPDIR/storescreens" "$INSTALL_DIR/storescreens"

echo "Installed storescreens to $INSTALL_DIR/storescreens"
