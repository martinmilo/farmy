# farmy update from a pre-release never goes back

Record 2026-10-29-1800 left open what `farmy update` without `--to` does on a pre-release: it would move to the
latest release, even an older one (0.3.0-rc.1 to 0.2.0). The owner, 2026-10-29:

> - farmy update from a pre-release must never downgrade: without --to it goes to the newest version that is not
>   older than the current one, release or pre-release; 0.3.0-rc.1 → 0.2.0 is refused with "newer than the latest
>   release; use --to 0.2.0 to go back".
> - Pre-release format X.Y.Z-rc.N and read-only commands refused next to an old container: keep.

So record 1800's choices of the pre-release form and of read-only commands next to a container of another
version or an out-of-date image stand as decided.

## Chosen here (the owner may overrule)

**How update learns of the newest pre-release.** Releases are found through moving tags, since the shim reads a
version only from an image's `farmy.version` label and needs no curl or registry API.
- `bin/release` of a pre-release also tags its four images `:next`, and never `:latest`. A stable release tags
  `:latest` as before.
- `bin/publish` and the release workflow stay stable-only.

**The rule for `farmy update` without `--to`:**
- An exact folder pin still comes first, like `--to`, even when it is older.
- From a stable version, update goes to `:latest` as before.
- From a pre-release, update reads the versions of control `:latest` and `:next`, and goes to the newest of them
  that is not older than the version it runs (SemVer order).
  - A `:next` that is missing, or cannot be pulled, counts as none.
  - When both are older, the update is refused (exit 1) with one line, the installed shim and every container
    left as they were:

    ```
    farmy: 0.3.0-rc.1 is newer than the latest release, 0.2.0; use --to 0.2.0 to go back
    ```

  - The same version is not older: an update that finds only itself installs it again.
- `farmy update --to <older>` goes back, as the refusal says.

## Existing tests that changed

- ReleaseTest "release publishes all four images … with their version, latest only for a stable version (a
  pre-release never moves latest), and metadata in the chosen registry" now reads "… their version, latest for a
  stable version and next for a pre-release, which never moves latest, …". Its helper checks `:next` for a
  pre-release.
- `published_release` takes `next_tag: true` to publish a version as `:next` too.

## Scenario list

InstallationTest:
1. From a pre-release, an update without `--to` goes to a newer pre-release (0.3.0-rc.2, published as next) when
   the latest release (0.2.0) is older.
2. From a pre-release, an update without `--to` goes to the latest release (0.3.0) when it is newer than the
   newest pre-release (0.3.0-rc.2).
3. From a pre-release, an update without `--to` never goes back: with 0.2.0 the latest release and no pre-release
   published as next, it is refused, saying the version is newer than the latest release and `use --to 0.2.0 to
   go back`. The installed shim is kept and no 0.2.0 image is pulled.
4. From a pre-release, `farmy update --to 0.2.0` goes back to 0.2.0.

ReleaseTest:

5. `bin/release` of the shipped pre-release tags `next` and never `latest` (the changed test).

## Not tested

- A `:next` that cannot be pulled for a reason other than its absence.
- Updating from a stable version when `:latest` is older (it does not happen with releases made in order).
