#!/bin/bash
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0" >&2
    exit 1
fi

check_bpftrace_version

W=/var/tmp/svp-selftest
RUNID="selftest$$"

cleanup_selftest() {
    stop_trace "selftest" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    unmount_apprun
    rm -rf "$W"
}
trap cleanup_selftest EXIT
trap 'cleanup_selftest; exit 130' INT TERM

rm -rf "$W"; mkdir -p "$W"
cp "$S/bin/probecheck" "$S/bin/svp-target" "$W/"

start_listeners
if ! start_trace "selftest"; then
    echo "tracer did not start" >&2
    exit 1
fi

( cd "$W" && ./probecheck "$RUNID" "$BASE_PORT" "$W/svp-target" ) > "$W/out" 2>&1

sleep 1
stop_trace "selftest"
stop_listeners

# The work directory is wiped by the exit handler, so the report has to outlive
# it: the failure messages below send the reader to it.
REPORT="$OUT/selftest.probecheck"
cp "$W/out" "$REPORT" 2>/dev/null || true

T="$OUT/selftest.trace"
fail=0
skip=0

check() {
    local label=$1 pattern=$2 syscall=${3:-$1}
    local n
    n=$(grep -ca "$pattern" "$T" 2>/dev/null; true)
    if [ "${n:-0}" -gt 0 ]; then
        printf '  ok   %-12s events %s\n' "$label" "${n:-0}"
    elif ! grep -qa "^ISSUED $syscall " "$REPORT" 2>/dev/null; then
        # A silent probe and a syscall that was never made look identical in
        # the trace, and the fix for them is not the same one.
        printf '  FAIL %-12s probecheck never issued it, see %s\n' "$label" "$REPORT"
        fail=$((fail + 1))
    else
        printf '  FAIL %-12s probe is silent, a zero in this column would mean nothing\n' "$label"
        fail=$((fail + 1))
    fi
}

# Legacy syscalls that some architectures do not have. The exemption is granted
# by probecheck's own report, not by the silence of the probe: on x86-64 open and
# unlink do exist, so a silent probe there is a defect, and calling it a skip
# would hide exactly the failure this self-test is for.
check_opt() {
    local label=$1 pattern=$2
    local n
    n=$(grep -ca "$pattern" "$T" 2>/dev/null; true)
    if [ "${n:-0}" -gt 0 ]; then
        printf '  ok   %-12s events %s\n' "$label" "${n:-0}"
    elif grep -qa "^SKIPPED $label " "$REPORT" 2>/dev/null; then
        printf '  skip %-12s not available on this architecture\n' "$label"
        skip=$((skip + 1))
    else
        printf '  FAIL %-12s issued by probecheck, probe stayed silent\n' "$label"
        fail=$((fail + 1))
    fi
}

echo
echo "probe self-test, every syscall issued directly through syscall()"
check_opt open      "^EVT .* open op=open .*$RUNID-pc-open"
check     openat    "^EVT .* openat op=open .*$RUNID-pc-openat\."
check     openat2   "^EVT .* openat2 op=open .*$RUNID-pc-openat2"
check     write     "^EVT .* write op=write .*$RUNID-pc-write"
check     writev    "^EVT .* writev op=write .*$RUNID-pc-writev"
check     pwritev   "^EVT .* pwritev op=write .*$RUNID-pc-pwritev"
check     pwrite64  "^EVT .* pwrite64 op=write .*$RUNID-pc-pwrite64"
check_opt unlink    "^EVT .* unlink op=unlink .*$RUNID-pc-open"
check     unlinkat  "^EVT .* unlinkat op=unlink .*$RUNID-pc-openat\."
check     connect   "^EVT .* connect op=connect"
check     execve    "^EVT .* execve op=exec .*$RUNID-pc-execve"
check     execveat  "^EVT .* execveat op=exec .*$RUNID-pc-execveat"
check     sched_exec "^EVT .* sched_exec op=exec .*$RUNID-pc-exec" execve

echo
if [ "$fail" -gt 0 ]; then
    echo "silent probes: $fail. Not running the measurement: those columns would"
    echo "be zero for a reason unrelated to the sandbox."
    exit 1
fi
[ "$skip" -gt 0 ] && echo "skipped (architecture): $skip"
echo "every probe catches its own syscall"
exit 0
