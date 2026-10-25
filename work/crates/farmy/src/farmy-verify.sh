#!/bin/sh
# farmy-verify [args…]: runs the factory run's verify command, with these words appended, on a snapshot of
# this tree as the iteration commit would make it, and passes its stdout and stderr on as they come, then
# exits with its exit code (FORMATS.md, "On-demand verify"). Its result decides nothing; the gate does.
#
# farmy mounts this file into the agent's container with two folders of the run's own: farmy-verify leaves
# its call in $FARMY_VERIFY_REQUESTS, and the run's controller writes the answer into
# $FARMY_VERIFY_RESPONSES (read-only here): <call>.out and <call>.err as the command prints, then
# <call>.exit. No farmy binary, Docker socket or network is involved.
requests=${FARMY_VERIFY_REQUESTS:-}
responses=${FARMY_VERIFY_RESPONSES:-}
if [ -z "$requests" ] || [ -z "$responses" ] || [ ! -d "$requests" ] || [ ! -d "$responses" ]; then
    echo 'farmy-verify: could not run: no factory run answers here (FARMY_VERIFY_REQUESTS and FARMY_VERIFY_RESPONSES name its folders)' >&2
    exit 125
fi

id="$(date +%Y%m%d%H%M%S)-$$"
call="$requests/$id"
# the words, each ended by a NUL byte; written beside and renamed, so that farmy never reads half a call
if ! { if [ "$#" -gt 0 ]; then printf '%s\0' "$@"; fi; } >"$call.tmp" || ! mv -f "$call.tmp" "$call.call"; then
    rm -f "$call.tmp"
    echo "farmy-verify: could not run: the call could not be left in $requests" >&2
    exit 125
fi

# interrupted: farmy stops the verify (an ending container takes its calls with it anyway)
interrupted() {
    : >"$call.cancel" 2>/dev/null
    exit "$1"
}
trap 'interrupted 129' HUP
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

out="$responses/$id.out"
err="$responses/$id.err"
status="$responses/$id.exit"

# pass FILE SENT: prints the bytes of FILE after the first SENT, and sets $sent to how many it has passed on
pass() {
    sent=$2
    [ -f "$1" ] || return 0
    size=$(wc -c <"$1" 2>/dev/null | tr -d ' ')
    case "$size" in '' | *[!0-9]*) return 0 ;; esac
    if [ "$size" -gt "$2" ]; then
        tail -c "+$(($2 + 1))" "$1" | head -c "$((size - $2))"
        sent=$size
    fi
}

sent_out=0
sent_err=0
polls=0
while :; do
    ended=no
    [ -f "$status" ] && ended=yes
    pass "$out" "$sent_out"
    sent_out=$sent
    pass "$err" "$sent_err" >&2
    sent_err=$sent
    [ "$ended" = yes ] && break
    # farmy takes a call as soon as it sees it, even while another verify runs
    if [ -e "$call.call" ]; then
        polls=$((polls + 1))
        if [ "$polls" -gt 300 ]; then
            rm -f "$call.call"
            echo 'farmy-verify: could not run: farmy did not take the call within 30 s (is the run still going?)' >&2
            exit 125
        fi
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
code=$(cat "$status" 2>/dev/null)
: >"$call.done" 2>/dev/null
case "$code" in '' | *[!0-9]*) code=125 ;; esac
exit "$code"
