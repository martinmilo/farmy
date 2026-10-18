# 2026-10-13 19:00 — The public face

The repository's root README is still the two-agent template's README. A developer who finds
farmy reads that first, and it says nothing about farmy. Three things, nothing else.

## Decided

1. **`README.md` at the root is for a developer who has never seen farmy**: one paragraph on what
   it is (containers per repository, agents inside, secrets outside, a TUI session); the
   requirement (Docker); the install (clone, put `work/farmy` on the PATH); the first service
   (`farmy init`, `farmy add <url> --image <image>`, `farmy start <name>`, `farmy` for the
   session); a short definition with `repo`, `image`, `ports`, `commands`, `mounts`; secrets in
   three lines pointing at `work/docs`; updating (`git pull`, `farmy update`). Examples use
   github.com and generic service names. The guides stay in `work/docs/` and the README links
   there.
2. **The template README becomes `CONTRIBUTING.md`**: the shape/work split, running the suite,
   where records go. Nothing of it stays in `README.md`.
3. **A test from outside**: `README.md` names every command `farmy help` lists, and no command it
   does not. "Names" means `farmy <command>` in a code span or a code block; prose such as "farmy
   runs" does not count.

The root files are outside both agents' folders: the owner writes them, the shaper's test holds
them to the usage.

## Scenario list

readme_test.rb
- the README at the root names every command the usage lists, and no command the usage does not
