#!/bin/bash
set -u

S="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0 [REPS]" >&2
    exit 1
fi

export REPS="${1:-${REPS:-3}}"

# Both arms and the summary must land in the same directory, so the session is
# named once here and inherited by the children.
export SVP_RUN_DIR="${SVP_RUN_DIR:-$S/results/$(date -u +%Y%m%dT%H%M%SZ)}"

trap 'exit 130' INT TERM

echo "############ build ############"
mkdir -p "$S/bin"
gcc -O2 -static -o "$S/bin/gen" "$S/src/gen.c" || exit 1
gcc -O2 -static -o "$S/bin/vminit" "$S/src/vminit.c" || exit 1
gcc -O2 -static -o "$S/bin/svp-target" "$S/src/target.c" || exit 1
gcc -O2 -static -o "$S/bin/probecheck" "$S/src/probecheck.c" || exit 1
echo "ok"

echo
echo "############ probe self-test ############"
# A run with a silent probe is worse than no run: its column would be zero for a
# reason unrelated to the sandbox, and that is indistinguishable from a result.
if ! "$S/run/selftest.sh"; then
    echo
    echo "aborted" >&2
    exit 1
fi

echo
echo "############ arm 1: host and gVisor ############"
"$S/run/host-and-gvisor.sh" || echo "arm 1 exited with an error" >&2

echo
echo "############ arm 2: virtual machines ############"
"$S/run/vms.sh" || echo "arm 2 exited with an error" >&2

echo
echo "############ summary ############"
"$S/analyze.sh" "$SVP_RUN_DIR"
echo
echo "artifacts: $SVP_RUN_DIR"

chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$S/results" 2>/dev/null || true
