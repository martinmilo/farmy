# Restore the Alpine control-image build and require real image builds

The owner reports that the control-image build fails when apk tries to install ruby-psych:
Alpine 3.21 has no package by that name. Remove that dependency; the Ruby installation
already supplies Psych. Explain why the build stage needs Ruby for the publishing work.
The worker will identify the exact build inputs and generated outputs without exposing
implementation files to the shaper.

The owner now requires a real build after every Dockerfile change and before committing
that change. A fake Docker run, workflow-structure check or host-language test does not
establish that an image builds. If the sandbox cannot perform the build, the report must
say so explicitly. Keep the Dockerfile changes uncommitted until a real build succeeds.
Persist this rule in both agents' instructions.

## Verification scenarios

1. A real build of the control image completes after the package dependency correction.
2. If another image recipe contains the same invalid dependency and is changed, build
   every affected target with a real builder before committing it.
3. If a builder is unavailable, report the failed build attempt and its reason, leave the
   recipe changes uncommitted, and make no claim that the image build was verified.

These scenarios directly follow the owner's instruction; no new product behavior or
approval is needed. Do not replace the real build with an assertion about package-name text.

## Outcome in this sandbox

The worker removed ruby-psych from work/Dockerfile and the shared build stage in
work/release.Dockerfile. Ruby runs bin/render-release, which reads release.yml and VERSION
and produces the configured shim, installer and SHA-256 checksum. Ruby remains in the
build stage; it is not installed in the final images.

Both attempted Docker builds exited 127 because docker is unavailable. No real image
build ran. The recipe corrections remain uncommitted. A builder must complete the
standalone control image and the release control, keys, knowledge and gate targets before
those recipe changes can be committed. Privacy checks do not substitute for these builds.
