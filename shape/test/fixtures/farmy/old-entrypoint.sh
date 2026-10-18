#!/bin/sh
# The app container's entrypoint as an older farmy built it, before entrypoint modes: whatever it is
# given (--git-config, --home, …) it does a normal startup and then waits forever.
echo "farmy-entrypoint: starting"
exec tail -f /dev/null
