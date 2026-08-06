#!/bin/bash
# Pull .debs from the GitHub Releases of every repo in sources.txt into the
# archive, then reindex whichever suites changed.
#
#   bin/ingest.sh <archive-dir>
#
# Pull-based on purpose: producing repos hold no credentials and need no
# workflow changes. Adding a new daemon to the archive is one line in
# sources.txt, not a deploy key and a copy of the signing key.
#
# Requires: gh (authenticated), dpkg-deb, apt-ftparchive, gpg.
set -euo pipefail

ARCHIVE=${1:?usage: ingest.sh <archive-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SOURCES=${SOURCES:-$HERE/../sources.txt}

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

added=0
declare -A touched_suites=()

while read -r repo; do
    # Skip blanks and comments.
    case "$repo" in ''|\#*) continue ;; esac
    echo "==> $repo"

    tags=$(gh release list --repo "$repo" --limit 50 --json tagName -q '.[].tagName' 2>/dev/null || true)
    if [ -z "$tags" ]; then
        echo "    no releases"
        continue
    fi

    for tag in $tags; do
        dl="$staging/dl"
        rm -rf "$dl"; mkdir -p "$dl"
        # No .debs on this release (docs-only tag, or an older release from
        # before packaging existed) — not an error.
        gh release download "$tag" --repo "$repo" --pattern '*.deb' --dir "$dl" >/dev/null 2>&1 || continue

        for deb in "$dl"/*.deb; do
            [ -e "$deb" ] || continue

            pkg=$(dpkg-deb -f "$deb" Package)
            ver=$(dpkg-deb -f "$deb" Version)
            arch=$(dpkg-deb -f "$deb" Architecture)

            # Rebuild the canonical filename from the control fields rather than
            # trusting the downloaded name: GitHub rewrites '~' to '.' in release
            # asset names, so an ingested file would otherwise be called
            # ..._0.1.0.alpha4-1_... while its actual Version is 0.1.0~alpha4-1.
            canonical="${pkg}_${ver}_${arch}.deb"

            # A '~' marks a pre-release (0.2.0~alpha1 sorts before 0.2.0), which
            # is exactly the set that must not reach machines tracking stable.
            case "$ver" in
                *~*) suite=testing ;;
                *)   suite=stable  ;;
            esac

            dest="$ARCHIVE/pool/$suite/main/${pkg:0:1}/$pkg/$canonical"
            if [ -e "$dest" ]; then
                continue
            fi

            mkdir -p "$(dirname "$dest")"
            cp "$deb" "$dest"
            echo "    + [$suite] $canonical  ($tag)"
            touched_suites[$suite]=1
            added=$((added + 1))
        done
    done
done < "$SOURCES"

if [ "$added" -eq 0 ]; then
    echo "==> nothing new to ingest"
    exit 0
fi

echo "==> ingested $added package(s); reindexing"
for suite in "${!touched_suites[@]}"; do
    "$HERE/build-repo.sh" "$ARCHIVE" "$suite"
done
