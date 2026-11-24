#!/bin/zsh
# Builds and runs the core tests (Sources/Core + Tests). No Xcode project needed.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc -swift-version 5 -target $(uname -m)-apple-macos14 -o build/tests Sources/Core/*.swift Tests/*.swift
# Tests never touch ~/.config/jackery-bar: everything goes to a throw-away folder.
TMPCFG=$(mktemp -d)
trap 'rm -rf "$TMPCFG"' EXIT
./build/tests --config "$TMPCFG/config.json"
