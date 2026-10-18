# Toolbox and dotfiles

Recorded on `farmy-workbench`, for the shaper and the worker. The order is this record with open
questions and scenarios, acceptance tests through the fake, then the worker's implementation, in
separate commits. The scenario list and the open contracts below come back to the owner before tests
fix their meaning.

An app container on an arm64 development machine has zsh with an empty configuration and none of
Neovim, Vim, ripgrep, fd, fzf or lazygit. The developer's environment must arrive with every app
container. Tools belong in images, dotfiles and reusable tool data belong on `farmy-shared`, and none
of this requires installing development tools or checking out dotfiles on the host.

## Open questions

1. **Catalogue shape and selection.** `tools: [neovim, ripgrep]` selects entries, but where do custom
   entries and overrides live in `farmy.yml` alongside that list? Settle the shared fields for version,
   release source, architecture/libc downloads, checksums and installation per base family, whether an
   override merges fields as agents do, and what an omitted tools list selects. Also settle how a
   user-supplied `toolbox/Dockerfile` consumes these selections and packages.
2. **Supported releases and bases.** Which base families and libc versions are supported by each
   official prebuilt asset? The architecture matrix must distinguish glibc and musl where their assets
   differ. What happens when a vendor lacks a compatible artifact? A named, actionable refusal is the
   proposed behavior; silently substituting an old distro tool would violate the request. Confirm the
   checksum algorithm and supported archive/install forms before fixtures encode them.
3. **Bump destination.** Where does `farmy toolbox bump` persist updated pins when the shipped catalogue
   lives in a released control image? Workspace overrides are a possible destination that needs no
   host checkout. Does the command update all catalogue entries or selected tools, how are custom
   vendors described, and does one missing asset or failed checksum leave the entire update unchanged?
   Settle stable versus prerelease selection and treatment of explicit user pins.
4. **Clone and update policy.** Which branch/ref is cloned, what happens if the configured repository
   changes, and how does pull handle local changes or a non-fast-forward update? Concurrent app starts
   must share one usable clone; settle how clone/pull failures are reported and whether they stop
   service startup. The existing git routes and broker remain the authentication path.
5. **Install and link behavior.** Settle the script's working directory, interpreter and startup order
   relative to shared-data setup and the service's setup command; running at the repository root as
   `dev` with the real home is proposed. For the fallback, settle existing-file conflicts, dot-directories
   such as `.config`, and exclusion of repository metadata such as `.git`. Never silently replace
   personal files. State how a failed installer in one container affects pull's result for the others.
6. **Shared data and login isolation.** Fix the directory layout for `~/.local/share`, platform/libc
   detection, ownership and any migration of existing home data. How does this coexist with dotfiles
   that contain `.local` and `shared_logins: false`, whose current test forbids any `farmy-shared`
   mount? Sharing tool data must not expose another service's private logins. State what simultaneous
   plugin installs can rely on; sharing a directory alone does not serialize a plugin manager.
7. **Shell defaults.** What shell is used when `shell` is absent, which values are accepted, and does
   selecting a shell install it automatically or require it in the image? `shell: zsh` must produce a
   usable dev login shell, and `farmy ssh` must use that selection.
8. **Factory boundary.** App images also supply factory binaries, but factory agents and gates currently
   have no `farmy-shared` mount and gates have a scratch home. Confirm the runtime scope of dotfiles and
   tool-data sharing for those containers without weakening their existing isolation.

## Required behavior

### Tools catalogue

Ship named entries for `neovim`, `ripgrep`, `fd`, `fzf`, `bat`, `lazygit`, `delta` and `jq`, following
the agents catalogue's data-driven approach. Each entry records its version and checksums for Linux
amd64 and arm64 and describes installation for each supported base family from the vendor's official
static or prebuilt release. Distro packages are not the source of these catalogue tools: the motivating
case is a distro Neovim too old for current plugin managers.

The requested ripgrep floor is 15.2, specified for its arm64 musl release. Actual shipped versions,
asset URLs and checksums must be verified against vendor releases when the catalogue is prepared;
this record supplies no guessed pins. An architecture/libc variant must use its own verified asset
and checksum, not another platform's values.

`farmy toolbox bump` reads the vendors' release information and updates versions and checksums.
Normal image builds consume pinned downloads and verify their checksums. They do not resolve a
moving latest version during each build.

In `farmy.yml`, `tools: [neovim, ripgrep, ...]` installs the selected tools into every app image's
toolbox layer. A service's `tools:` adds tools for that service. Users can define catalogue entries
in `farmy.yml` with the same fields and installation behavior as shipped entries.

### Distro packages

Workspace `packages:` and service `packages:` contain distro package names for dependencies outside
the catalogue, for example `libvips`, `imagemagick` and `postgresql-client`. They are installed in the
toolbox layer with the base family's package manager. Global packages reach every app; service
packages are additional and do not affect another service. These names are passed to that distro,
not translated into a second catalogue of equivalent package names.

### Dotfiles lifecycle

```yaml
# farmy.yml
tools: [neovim, ripgrep, fd, fzf, bat, lazygit, delta, jq]
packages: [libvips, imagemagick]
dotfiles:
  repo: https://git.example.com/dev/dotfiles.git
  install: install.sh
shell: zsh
```

Clone the dotfiles repository once into `farmy-shared/dotfiles`. Cloning uses the git routes just
like an application clone: a private HTTPS repository works through a token route and a private SSH
repository through an SSH route and the broker. Credentials do not enter the app environment, clone
URL or command line. A second app reuses the clone.

Every app container runs the configured script from that repository as `dev` at start, so it can
symlink configuration into `$HOME`. Without `install`, farmy links the repository's top-level
dotfiles into `$HOME` according to the conflict and directory rules settled above.

`farmy dotfiles pull` updates that shared clone and reapplies it in running app containers: run the
install script again, or refresh the default links when no script is configured. Later starts use
the updated clone. The clone and installations run inside containers; the host needs no Git,
editor, package manager or dotfiles checkout for this feature.

### Shared tool data and shell

Plugin managers download and compile under `~/.local/share`, including lazy.nvim and treesitter
parsers. That data lives on `farmy-shared` in a directory per platform and libc, such as
`linux-arm64-glibc`. Containers on one machine with the same platform/libc reuse it. A different
architecture or libc uses a separate directory, so an Alpine app never loads a Debian-built parser.
The exact parent path is an open contract; the platform/libc separation is required.

`shell: zsh` in `farmy.yml` sets dev's login shell. `farmy ssh` starts that login shell and reaches
the developer's configuration. Shell selection and configuration are part of the container, not
dependencies installed on the host.

## Tests through the fake

Observe the toolbox Dockerfile and the context submitted to the fake build, the Docker/Compose
operations, git requests through real broker routes, and files in fake volumes. The Dockerfile must
carry each selected tool's pinned download and checksum for each architecture, and the build must
actually verify the checksum before installing it. The fake records these inputs; it must not
invent catalogue resolution, checksum success or dotfile installation on farmy's behalf.

Vendor-release fixtures make bump deterministic and offline. Script fixtures leave observable files
and report their user and home. The two git-route cases use the existing fake git host and broker
arrangements. Real-image checks separately prove that the downloaded binaries execute.

## Scenario list

- The shipped catalogue contains all eight requested tools with official release sources, versions and architecture-specific checksums, with ripgrep at least 15.2.
- Each selected catalogue tool contributes its pinned amd64 download and checksum to the toolbox Dockerfile and installs without using that tool's distro package.
- Each selected catalogue tool contributes its pinned arm64 download and checksum to the toolbox Dockerfile and installs without using that tool's distro package.
- A supported musl base selects a compatible pinned artifact rather than a glibc artifact.
- A failed checksum stops installation and identifies the tool and artifact.
- Workspace tools are installed in every app image and service tools add only to that service's image.
- A user-defined catalogue entry installs through the same architecture and base-family fields as a shipped entry.
- An unknown selected tool or incomplete required artifact is refused with an actionable name and reason.
- Toolbox bump reads fixture vendor releases and persists the new version and both architecture checksums in the agreed destination.
- A failed or incomplete vendor update preserves the previously usable pins according to the agreed bump transaction policy.
- Workspace packages reach every toolbox build and a service's packages reach only its build through the correct base-family package manager.
- A private HTTPS dotfiles repository clones through its token route without leaking the token to the app or command line.
- A private SSH dotfiles repository clones through its SSH broker route without giving the app a private key.
- Starting another app reuses the single shared dotfiles clone.
- Concurrent app starts leave one complete usable dotfiles clone under the agreed initialization policy.
- Each app start runs the configured installer as dev with the expected repository directory and home.
- Without an install script, top-level dotfiles are linked into home with the agreed metadata exclusions and conflict behavior.
- Dotfiles pull updates the shared clone and reruns the installer as dev in every running app container.
- Dotfiles pull refreshes the default links when no installer is configured and later app starts use the updated clone.
- A failed clone, pull or installer reports the affected operation and container under the agreed failure policy.
- Two apps on the same platform and libc see the same dev-writable local share data and reuse an installed plugin.
- Linux arm64 glibc, Linux arm64 musl and Linux amd64 glibc use distinct shared-data directories.
- Destroying one service preserves the shared dotfiles clone and tool data used by other services.
- A service with private logins can use shared tool data without exposing another service's login files under the agreed mount contract.
- Configuring zsh sets dev's login shell and farmy ssh invokes it with the installed dotfile configuration.
- A real Linux arm64 app image runs nvim --version and rg --version and reports the catalogue's selected versions.
- A real Linux amd64 app image runs nvim --version and rg --version and reports the catalogue's selected versions.

The integration pair must execute binaries on both architectures, natively or with an explicitly
available emulator. Observing a multi-architecture Dockerfile is not execution evidence. An unavailable
Docker daemon or architecture is a reported skip, not a passing integration check. Contract-dependent
scenario details are settled before test bodies are written.

## Existing contracts affected

The toolbox and agents tests already inspect generated build inputs. Extend that public observation
without reading worker source. Existing custom-toolbox behavior needs the agreed catalogue/package
contract; it must not silently discard the user's tools.

`test/farmy/mounts_test.rb` currently requires `shared_logins: false` to mount no `farmy-shared` at all.
That assertion needs a new decision before it can coexist with shared dotfiles and tool data. Its
login-isolation purpose and the corresponding integration test stay meaningful. The factory test
requiring no shared volume also remains a boundary to settle, not permission to expose shared data.

The older shared-volume record and the toolbox section of `FORMATS.md` do not yet specify libc-safe
local share paths. This record extends that behavior; it does not claim every prebuilt tool runs on
every accepted Alpine image.

## Worker handoff

After confirmation, the shaper reads `TESTING.md`, adds acceptance tests and any fake capabilities,
and checks that new failures explain the missing behavior. Put the settled catalogue/config schema,
bump storage, build inputs, startup/link rules, shared paths, command results and shell contract in
`FORMATS.md`, which the worker can read. Commit this separately from implementation on
`farmy-workbench`.

The worker then implements against `bin/verify` output and `FORMATS.md`, preserving the separation
between tests and source. Verify the full suite and run the real-image version checks on both
architectures where available, recording any unavailable integration coverage. No host dotfiles
manager, automatic host package installation or editor/plugin configuration of farmy's own is added.
