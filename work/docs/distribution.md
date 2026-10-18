# Install, update and release farmy

The host needs Docker and ordinary POSIX utilities. The installed `farmy` is a standalone
shell executable; Rust, Git, curl, jq and a host language runtime are not required. The
control image contains the tools used inside containers.

## Install a published release

Download the GitHub release's `install` and `SHA256SUMS` assets linked by the root README.
Verify them with `sha256sum --check SHA256SUMS` (or `shasum -a 256 --check SHA256SUMS` on macOS),
then run `sh install`. The default registry is `ghcr.io/<owner>/farmy`, derived from the one
`release.yml` configuration. Environment overrides select another publisher when needed:

```sh
FARMY_REGISTRY=ghcr.io/acme sh bin/install
# Or a Forgejo registry:
FARMY_REGISTRY=forgejo.example.com/acme sh bin/install
```

The installer pulls `farmy-control:latest`, reads its `farmy.version` label, then pulls that
exact version. Docker create/cp/remove extracts `/usr/local/lib/farmy/farmy` without running
a container binary. Only `$HOME/.local/bin/farmy` is installed. Add that directory to PATH.
Choose an exact version or another destination with:

```sh
FARMY_REGISTRY=ghcr.io/acme sh bin/install --to 0.1.0 --dir "$HOME/bin"
farmy --version
```

The executable remembers its registry and matching GitHub tag source. Nonempty environment
overrides take precedence; empty overrides use saved values. Install and update stage the
new executable beside the destination, replacing it atomically after pull and extraction
succeed. Failures keep the old executable. Update failures leave running containers unchanged.

For a private registry, sign in with Docker first. GitHub's registry uses `ghcr.io/OWNER`;
its guide covers token scopes, workflow tokens and anonymous public-image access. See the
[official GitHub container registry guide](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).
Forgejo uses `REGISTRY/OWNER/IMAGE`; use `docker login` for the instance, with a personal
access token for accounts using 2FA or OAuth. See the
[official Forgejo container registry guide](https://forgejo.org/docs/latest/user/packages/container/).

## Update and folder pins

```sh
farmy update                 # exact folder pin, otherwise newest published release
farmy update --to 0.1.0      # explicit target takes precedence over the folder pin
```

Update pulls the selected exact version of all four images: control, keys, knowledge and
gate. It extracts and replaces the shim, preserving the selected registry and any explicit
source override. The generated default source advances to the installed version's mirror tag.
It does not edit `farmy.yml`. The next ordinary command selects the new control image and
recreates the control container when needed; updating the executable leaves sessions running
until that selection occurs.

Pin a containers folder in `farmy.yml`:

```yaml
farmy: '0.1.0' # exact MAJOR.MINOR.PATCH; quotes are optional
format: 1
```

Ordinary commands refuse a mismatched pin and show `farmy update --to <pin>`. `--version`
and `update` remain available. Versions cannot be ranges, have a `v` prefix, leading zeros
or a prerelease suffix. Keep compatibility fields as ordinary top-level scalars, once each;
ambiguous values are refused without evaluating YAML or shell code on the host.

Both `farmy.yml` and service definitions accept a positive integer `format`; absence means
1. A future format is refused before changing containers, even with unfamiliar future keys.
The refusal names the file and format. If latest control metadata identifies a capable
reader, it names that release; otherwise it says the required version is unknown and suggests
`farmy update`. Discovery never executes the file through a new reader automatically.

Status and the session identify older toolbox images with
`built by <old>, now <current>: farmy rebuild <service>`. JSON includes `toolbox_version`
and `toolbox_outdated`; equal or newer versions are not marked outdated. The shim also warns
when the running control image is newer than itself, with both versions and the update command.
An existing app image without a valid version label says
`built by an unknown farmy: farmy rebuild <service>` and has a null JSON version with outdated true.
This also applies to stopped apps; a service that has never had an image is not marked outdated.
Status reads a container's immutable image identity before considering the current local image tag.

## Local development and source fallback

The shim normally pulls `<registry>/farmy-control:<its-version>` and reports pulling or
building. If a pull fails it reports that failure and tries a build from its checkout.
A standalone install automatically falls back to the matching mirror tag's `work/` Docker
context. A different source can be selected explicitly:

```sh
export FARMY_REGISTRY=ghcr.io/acme
export FARMY_SOURCE='https://github.com/acme/farmy.git#v0.1.0:work'
sh bin/install
```

Docker fetches the context; farmy does not clone it on the host. Choose a source ref matching
the desired release. Release artifacts already contain the configured mirror fallback.

In a checkout, ordinary `farmy init` checks cached control against its complete build-input digest.
Changed inputs rebuild control and replace its stale container without requiring `FARMY_BUILD=1` or
a version bump. Unchanged inputs reuse both. Recipes, ignore rules, copied files and directories,
contents, modes, types, and symlink targets contribute to the digest; build outputs do not.
The binary's build hash and locally built image's hash use the same fingerprint. An unreadable or
vanished input fails the build rather than reusing an uncertain cache entry.

When no control image is cached, an explicitly configured registry still supplies the initial image;
a failed pull is reported before local fallback. `FARMY_BUILD=1 /path/to/farmy/work/farmy init` skips
that published pull and builds locally. With this flag, targetless `update` also uses source caching.
The local control tag is `farmy:local`.
Development helper images also build locally; published operation pulls matching versions.

## Build or publish a release

Run these commands from the implementation directory containing `VERSION`. That file supplies
the release identity for binaries, TUI, shim and farmy-owned images. Image labels carry
`farmy.version` and nonempty `farmy.hash`; control also carries `farmy.format`, the highest
readable document format. Vendor base images and sidecars keep their own labels.

Publishing requires a Docker buildx builder for `linux/amd64,linux/arm64` and registry
credentials with push access. The configured default is GHCR; an override selects another destination:

```sh
docker login ghcr.io
FARMY_REGISTRY=ghcr.io/acme bin/release "$(cat VERSION)"
# Or:
docker login forgejo.example.com
FARMY_REGISTRY=forgejo.example.com/acme bin/release "$(cat VERSION)"
```

This publishes `farmy-control`, `farmy-keys`, `farmy-knowledge` and `farmy-gate`, with exact
version and `latest` tags for both platforms. Registry paths and ports are supported. A
mismatched version is refused before publication. VERSION and user files
are never edited. Failed build/push exits nonzero; images already pushed earlier in that
invocation may remain published.

To check a real build without publishing or configuring a registry:

```sh
bin/release "$(cat VERSION)" --image gate --output /tmp/farmy-gate.oci.tar
```

This exports one OCI archive for both platforms with the same inputs and labels. Roles are
`control`, `keys`, `knowledge` and `gate`. Archive paths cannot contain commas. The optional
real-build acceptance check skips when Docker or a builder for both targets is unavailable.

CI is optional. After checkout, builder setup and Docker login, a manual job can use the
same commands. These example job steps select the registry through CI configuration:

```yaml
steps:
  - name: Check the gate image without publishing
    working-directory: work
    run: bin/release "$(cat VERSION)" --image gate --output /tmp/farmy-gate.oci.tar
  - name: Publish the selected release
    working-directory: work
    env:
      FARMY_REGISTRY: ${{ vars.FARMY_REGISTRY }}
    run: bin/release "$(cat VERSION)"
```

Use your CI system's manual publication controls and registry credentials. The release
command has no dependency on a particular CI provider or registry.

## Public release snapshots

`release.yml` is the single public build-time configuration: the registry is
`ghcr.io/<owner>/farmy`, and standalone source fallback is
`<github_url>.git#v<version>:work`. The configuration records the public owner, URLs and
maintainer identity. Replace the account-number placeholder in `maintainer_email` with the
maintainer's real GitHub noreply address before publishing. Build-time rendering
embeds these defaults in the shim and release installer. An environment override wins.
Updating a generated source default advances its version tag; a custom source override stays.

From the private repository root, run `bin/publish <version>`. It requires committed input,
a matching stable `work/VERSION`, versioned `work/releases/<version>.md` notes with contributor
credits, and a readable nonempty denylist named by `PRIVATE_TERMS_FILE`, a file kept outside the repository;
no default is written anywhere, and both `bin/publish` and `bin/scan-private` refuse to run without
it. The ordinary test suite skips its privacy test, loudly, when the variable is unset; publication cannot.
`work/public-files.txt` is a reviewed allowlist retaining `work/` and `shape/`, including the
public acceptance tests and spec records. It excludes private configuration, generated state,
build products and internal notes. Both privacy scanners check the isolated public candidate,
including filenames, binary bytes, symlink targets, deleted historical content and tag metadata.
Any hit or scanner error prevents the push.

The scanner permits the exact configured identity in release configuration scalars, Git
author/committer/tagger headers and the root LICENSE copyright attribution. Root README and
CONTRIBUTING links may use the exact configured public URLs and prescribed release-asset URLs.
Names in prose, paths or messages remain subject to the denylist. Tree scans use the working
configuration, staged scans use its index version, and history scans use the committed
configuration at HEAD to check all history, including older release configurations.

The first public release is a parentless commit. Each later release adds one squashed commit
with exactly the previous public main tip as parent. Author, committer and tagger use the public
maintainer identity. No private development objects, refs, messages or commit IDs enter that
repository. An identical repeated release is a no-op; conflicting versions, older versions,
untagged public history, unsafe links and remote races are refused. Main and the annotated
version tag are pushed atomically with an expected-tip precondition; unsupported atomic pushes
are refused. A failed push can be retried without duplicate release history.

Configure a Forgejo push mirror externally for public main and release tags. Its GitHub
credential must be able to update workflow files and trigger tag CI; store it in Forgejo's
secret configuration, never the public tree. Local publication success means Forgejo accepted
the refs. GitHub synchronization, image builds and release assets remain pending/unverified.

`.github/workflows/release.yml` is the real tag workflow. It builds control, keys, knowledge and
gate natively on `ubuntu-24.04` (linux/amd64) and `ubuntu-24.04-arm` (linux/arm64), pushes immutable
GHCR digests using `GITHUB_TOKEN`, then merges each role's two digests as version and latest.
All eight builds must succeed before any manifest, and all manifests must succeed before the
GitHub release assets. The attached `install` and `SHA256SUMS` are rendered together and their
SHA-256 checksum is verified over the exact installer bytes. The workflow uses maintained
versioned notes for contributor credit. Registry updates across four images are not atomic;
a failed job can be retried. Local tests inspect this workflow; the actual run happens on GitHub.

GitHub issues accept reports. Pull requests there are proposals: maintainers apply accepted
changes in the source repository and publish them in the next release, crediting contributors
in the release notes. The mesh-only Forgejo host is not internet intake. Optional PR notices
are enabled by repository variable `FARMY_PR_NOTICE=true`; they never execute proposal code.
