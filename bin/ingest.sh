#!/bin/bash
# Pull .debs from the GitHub Releases of every repo in sources.txt into the
# archive, vendor any pinned third-party packages, then reindex whichever
# suites changed.
#
#   bin/ingest.sh <archive-dir>
#
# Pull-based on purpose: producing repos hold no credentials and need no
# workflow changes. Adding a new daemon to the archive is one line in
# sources.txt, not a deploy key and a copy of the signing key.
#
# Requires: gh (authenticated), dpkg-deb, apt-ftparchive, gpg, curl.
set -euo pipefail

ARCHIVE=${1:?usage: ingest.sh <archive-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SOURCES=${SOURCES:-$HERE/../sources.txt}
PINNED=${PINNED:-$HERE/../pinned-packages.txt}

# Every suite a pinned package is vendored into. Kept as a fixed list rather
# than derived from whatever's already in the archive: a pinned package must
# reach a suite before that suite has ever seen it (e.g. a brand new archive,
# or the first run after a suite's pool was pruned).
SUITES="stable testing"

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

# ── Pinned third-party packages ─────────────────────────────────────────────
# Vendored straight from a fixed URL rather than pulled from a GitHub Release:
# these aren't braemons packages, they're a specific upstream build a rig
# needs to stay on because a newer one regresses hardware. Placed into every
# suite unconditionally — the hardware issue a pin works around doesn't care
# which channel a rig tracks.
if [ -f "$PINNED" ]; then
    while read -r pkg ver arch url; do
        # Skip blanks and comments.
        case "$pkg" in ''|\#*) continue ;; esac
        echo "==> $pkg $ver $arch (pinned)"

        canonical="${pkg}_${ver}_${arch}.deb"

        for suite in $SUITES; do
            dest="$ARCHIVE/pool/$suite/main/${pkg:0:1}/$pkg/$canonical"
            if [ -e "$dest" ]; then
                continue
            fi

            tmp="$staging/$canonical"
            curl -fsSL -o "$tmp" "$url"

            # Trust but verify: a typo'd version/url in pinned-packages.txt
            # must fail loudly here, not silently vendor the wrong build
            # under a filename that claims otherwise.
            got_pkg=$(dpkg-deb -f "$tmp" Package)
            got_ver=$(dpkg-deb -f "$tmp" Version)
            got_arch=$(dpkg-deb -f "$tmp" Architecture)
            if [ "$got_pkg" != "$pkg" ] || [ "$got_ver" != "$ver" ] || [ "$got_arch" != "$arch" ]; then
                echo "    ! $url doesn't match: got $got_pkg $got_ver $got_arch, expected $pkg $ver $arch" >&2
                rm -f "$tmp"
                exit 1
            fi

            mkdir -p "$(dirname "$dest")"
            mv "$tmp" "$dest"
            echo "    + [$suite] $canonical"
            touched_suites[$suite]=1
            added=$((added + 1))
        done
    done < "$PINNED"
fi

if [ "$added" -eq 0 ]; then
    echo "==> nothing new to ingest"
    exit 0
fi

echo "==> ingested $added package(s); reindexing"
for suite in "${!touched_suites[@]}"; do
    "$HERE/build-repo.sh" "$ARCHIVE" "$suite"
done
