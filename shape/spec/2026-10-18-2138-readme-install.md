# The README's install section for 0.1.1: one line first, the verified download second

The owner wants the install section to lead with a single line a newcomer can paste, and to keep the
checksum-verified variant right after it:

1. `curl -fsSL https://github.com/<owner>/farmy/releases/latest/download/install | sh`
2. Download `install` and `SHA256SUMS` from the same release, check them (`shasum -a 256 --check SHA256SUMS` on
   macOS, `sha256sum --check SHA256SUMS` on Linux), then `sh ./install`.

Decided (the owner, 2026-10-18):
- The installer a release attaches (rendered by `work/bin/render-release`) installs, without `--to`, the
  release it came from, even when a newer release is `latest`: the versioned download of 0.1.1 installs
  0.1.1. The checkout's `bin/install` keeps resolving `latest` (InstallationTest, unchanged). `--to` wins in
  both.
- The installer ends by saying which version it installed and where, and, when that folder is not on
  `PATH`, prints the line that puts it there: `export PATH="<dir>:$PATH"` with the folder written out. On
  `PATH`, no such line.
- A test holds every release download URL in the README to the release's naming: `<github_url>` followed by
  `/releases/latest/download/<asset>` or `/releases/download/v<x.y.z>/<asset>`, where `<asset>` is a file the
  release workflow attaches (`install`, `SHA256SUMS`), so a renamed asset cannot silently break the README.

Left out, a later record: a Homebrew tap.

## Scenarios (ReleaseInstallerTest, ReadmeInstallTest)

1. The release's installer, run without --to, installs the release it came from even when a newer one is
   latest.
2. The release's installer with --to installs that version.
3. The installer ends by naming the version and the folder, and the export line when the folder is not on
   PATH.
4. On PATH, the installer prints no export line.
5. The README's install section leads with the one-line installer from the latest release, then the
   checksum-verified download from the same release, for macOS and Linux.
6. Every release download URL in the README follows the release naming and names an asset the release
   workflow attaches.
