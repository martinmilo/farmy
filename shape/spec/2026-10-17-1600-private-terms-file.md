# The denylist is named by PRIVATE_TERMS_FILE, with no default anywhere

Supersedes the denylist location of 2026-10-15-0300 and 2026-10-15-1625. bin/publish and bin/scan-private
are public files, and both carried the owner's machine path to the denylist as a default.

Decided (the owner, 2026-10-17): both read the denylist's path from `PRIVATE_TERMS_FILE`; no default is
written in any file. bin/scan-private (and bin/scan-history, which uses it) and bin/publish refuse to run
when it is unset or names a missing or unreadable file, naming the variable or the path; publication also
refuses an empty list. The term format and the rule that the file lives outside the repository stay as
they were. The acceptance suite's privacy test skips, loudly, when the variable is unset; the kit has no
default either. The pre-commit hook (bin/scan-private --staged) therefore needs PRIVATE_TERMS_FILE in
the committer's environment.

Because spec records are public too, the machine path in 2026-10-15-0300 was redacted in place on
2026-10-17; that is the only edit made to an older record, made for the privacy rule.

Tests: PublishingPrivacyTest "a unset/missing/empty/unreadable publication denylist refuses every push
rather than skipping the privacy check, naming PRIVATE_TERMS_FILE"; "scan-private refuses to run when
PRIVATE_TERMS_FILE is unset, naming the variable"; "… names a file that does not exist, naming the path".
