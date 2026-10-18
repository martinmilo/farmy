# The holder's socket is never open to others

Found in the lint sweep (hold.rs:99): the holder binds its socket and then chmods it to 0600; a failed
chmod was ignored, leaving the socket with the umask's mode, so another user on the host could ask the
holder for the unlocking values it keeps in memory.

Decided (the owner, 2026-10-17), before 0.1.0: fail closed. farmy sets a restrictive umask before it
binds, so the socket is never created open, and if the socket still cannot be made 0600 it removes the
socket and refuses to start, naming the path and the error.

Tests: HoldTest "the holder's socket is 0600 even when farmy runs with umask 000" (acceptance; it may
pass today, because the chmod normally works, and guards the umask path). A failing chmod cannot be
provoked from outside, so the refusal is a Rust unit test in work/ with the chmod failure injected:
the socket is removed and the error names the path.
