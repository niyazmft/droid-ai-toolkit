#!/bin/bash
# scripts/lint_kotlin.sh -- ktlint over the Android sources.
#
# Same shape as `npx --yes shellcheck`: fetch the pinned tool once into a cache, then
# run it. ktlint is a JVM program, so a JRE must be present (CI installs JDK 17; the app
# build needs it anyway).

set -u

VERSION="1.3.1"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ktlint-$VERSION"
BIN="$CACHE/ktlint-$VERSION/bin/ktlint"

if [ ! -x "$BIN" ]; then
    mkdir -p "$CACHE" || { echo "cannot create $CACHE"; exit 1; }
    zip="$(mktemp)"
    url="https://github.com/pinterest/ktlint/releases/download/$VERSION/ktlint-$VERSION.zip"
    if ! curl -fsSL -o "$zip" "$url"; then
        echo "could not download ktlint $VERSION from $url"
        rm -f "$zip"
        exit 1
    fi
    if ! unzip -q -o "$zip" -d "$CACHE"; then
        rm -f "$zip"
        exit 1
    fi
    rm -f "$zip"
fi

if ! command -v java >/dev/null 2>&1; then
    echo "ktlint needs a JRE (JDK 17 for this project); install one or skip with --no-ktlint"
    exit 1
fi

# .editorconfig in apk/ carries the ktlint settings (Compose naming, line length).
"$BIN" --relative "apk/**/*.kt"
