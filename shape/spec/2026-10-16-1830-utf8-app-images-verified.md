# App images with LANG=C.UTF-8: verified on a real build

Follows 2026-10-16-1730 (records are not edited; this one adds the verification).

The toolbox change of 2026-10-16-1730 was committed unbuilt (work commit 7cacd22, "unbuilt
here, build on the owner's machine"). The owner built it on their machine on 2026-10-16:

- the toolbox image builds;
- inside the app container LANG=C.UTF-8 and `locale charmap` answers UTF-8;
- nvim reports v0.12.6;
- the dotfiles are applied.

Status: **verified on a real build.** Nothing from 7cacd22 still needs a real build.
