# The shipped version in one place

Bumping `work/VERSION` to 0.1.1 for the 0.1.1 release turned 22 tests red. They wrote `0.1.0` wherever they
meant "the version this checkout ships": `farmy --version`, the release images and their labels, the
installer's default, the folder pin, the toolbox's "now <version>". A test that pins the shipped version
is right to fail when it changes, but only in one place.

Decided (the owner set 0.1.1 on 2026-10-19):

- `Distribution::SHIPPED` holds the shipped version, `0.1.1`, and "the distribution exposes its single
  version source as VERSION" checks `work/VERSION` against it. Every test that meant the shipped version
  uses it. Tests about an older (`0.0.9`) or newer (`0.2.0`) release keep their literals.
- Changed meaning, by name: "the repository starts at version 0.1.0 with a build hash" is now "farmy
  --version names the shipped version with a build hash"; "a toolbox built by … is not marked older than
  0.1.0" now names the shipped version.
- Publication's own scratch repositories (PublishingTest, ReleaseIdentityTest, the workflow fixtures) keep
  their own `VERSION` and are untouched.

At the next release, only `SHIPPED` changes here.
