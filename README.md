# braemons packages

Signed apt archive for braemons daemons, served at
**<https://braemons.github.io/packages/>**.

Machines running braemons software update in place with `apt upgrade` instead of
being re-imaged — which would discard `/etc/braemons` (rig configs and saved
stimulus configs) and `/var/lib/braemons`.

## Using it

Images built from a recent release come configured already. To add the archive
to an existing machine:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/braemons.asc \
    https://braemons.github.io/packages/braemons-archive-keyring.asc

sudo tee /etc/apt/sources.list.d/braemons.sources >/dev/null <<'EOF'
Types: deb
URIs: https://braemons.github.io/packages
Suites: stable
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/braemons.asc
EOF

sudo apt update && sudo apt upgrade
```

Use `Architectures: amd64` on a desktop rig. The key is kept ASCII-armored as
`.asc`, which apt reads directly — dearmoring would need `gpg(1)`, which is not
guaranteed present on a Lite image.

### Suites

| Suite | Contents |
| --- | --- |
| `stable` | Plain releases (`v0.2.0` → `0.2.0`) |
| `testing` | Pre-releases (`v0.2.0-alpha1` → `0.2.0~alpha1`) |

Sorted into suites automatically: a `~` in the version marks a pre-release. `~`
sorts *before* the empty string, so `0.2.0~alpha1` < `0.2.0` and a machine
tracking `stable` is never offered a pre-release. Each suite has its own pool,
so the split is real rather than just an index filter.

### Machines with no internet

The archive is static files, so mirror it and point closed machines at the copy:

```bash
wget -mnH --cut-dirs=1 -R 'index.html*' https://braemons.github.io/packages/
rsync -a packages/ lab-server:/var/www/html/braemons/
```

Then use `URIs: http://lab-server/braemons`. Signatures still verify — they
cover the archive contents, not where it was fetched from — so the mirror needs
no key of its own.

## Adding a project

One line in [`sources.txt`](sources.txt):

```
braemons/some-daemon
```

That is the whole integration. The source repo needs no workflow changes and
holds no credentials — it just attaches `.deb`s to its GitHub Releases, and this
archive pulls them.

## Pinning a third-party package

Sometimes a rig needs to stay off a package this archive doesn't build at all —
a specific upstream Debian/vendor build, held at a known-good version because a
newer one regresses hardware a rig depends on. That's a different problem from
`sources.txt`: there's no GitHub Release to pull from, and the pin has to reach
a rig regardless of whether it tracks `stable` or `testing`.

One line in [`pinned-packages.txt`](pinned-packages.txt):

```
mesa-vulkan-drivers  25.0.7-2+rpt4+deb13u1  arm64  http://archive.raspberrypi.com/debian/pool/main/m/mesa/mesa-vulkan-drivers_25.0.7-2+rpt4+deb13u1_arm64.deb
```

`ingest.sh` downloads the `.deb`, checks its control fields (`Package`/
`Version`/`Architecture`) match the line before vendoring it — a typo'd version
or URL fails the run rather than silently shipping the wrong build under a
filename that claims otherwise — and copies it into every suite's pool, since
the hardware issue a pin works around doesn't care which channel a rig tracks.

Once pinned, `apt upgrade` on a rig can never move that package off the pinned
version: this archive is the only source rigs are configured to trust, and it
never publishes anything else under that name. Un-pin by deleting the line and
the corresponding pool files.

## How publishing works

`.github/workflows/publish.yml` runs on a 30-minute schedule, on pushes that
touch the tooling, and on demand via **Run workflow**:

1. Seeds a working copy from the published `gh-pages` branch, so ingestion is
   incremental and the other suite survives untouched.
2. Reads `sources.txt` and downloads `.deb` assets from each repo's releases.
3. Reads `pinned-packages.txt` and vendors each entry into every suite.
4. Skips anything already in the pool; files release `.deb`s into `stable` or
   `testing` by version.
5. Regenerates `Packages`/`Release` for the affected suites, signs `InRelease`
   and `Release.gpg`, and pushes to `gh-pages`.

Filenames are rebuilt from each package's control fields
(`<package>_<version>_<arch>.deb`) rather than trusting the downloaded name:
GitHub rewrites `~` to `.` in release asset names, so an ingested file would
otherwise be called `..._0.1.0.alpha4-1_...` while its actual `Version:` is
`0.1.0~alpha4-1`.

Runs are serialised by a concurrency group — two pushes to `gh-pages` at once
would race and the second would be rejected.

Nothing publishes unsigned: without `APT_SIGNING_KEY` the workflow fails rather
than producing an archive apt would only accept with `[trusted=yes]`.

## Building locally

```bash
sudo apt-get install -y apt-utils gnupg
bin/ingest.sh archive                 # pull releases into ./archive
bin/build-repo.sh archive stable      # reindex one suite
```

Export `APT_SIGNING_KEY` (ASCII-armored private key) to sign; without it the
suite is built unsigned, which is fine for a local test and nothing else.

## The signing key

Public half: [`braemons-archive-keyring.asc`](braemons-archive-keyring.asc),
fingerprint `0435E6ED C19F085E F0F62F22 A2BCE0FF 045159C5`. Private half lives
only in this repository's `APT_SIGNING_KEY` secret and in offline backup.

It has no passphrase, because CI cannot type one — so treat the exported private
key as a credential in its own right and keep it in a password manager, not a
file on a shared drive. Anyone holding it can sign packages that every braemons
machine will install as root.

Rotating it means updating `/etc/apt/keyrings/braemons.asc` on every deployed
machine and in every image, so it is worth backing up properly rather than
regenerating.
