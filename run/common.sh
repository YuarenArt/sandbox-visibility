S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# sudo clears the environment, so operator paths are read from a file.
[ -r "$S/config.local" ] && . "$S/config.local"

# One directory per session. Overwriting in place once destroyed the artifacts
# behind an already published table.
OUT="${SVP_RUN_DIR:-$S/results/$(date -u +%Y%m%dT%H%M%SZ)}"

# The release build is an AppImage over a nix bundle and has to be unpacked;
# running it directly mounts itself over FUSE and fails on /nix/store paths.
BPFTRACE="${SVP_BPFTRACE:-}"
if [ -n "$BPFTRACE" ] && [ ! -x "$BPFTRACE" ]; then
    echo "SVP_BPFTRACE points at something that is not executable: $BPFTRACE" >&2
    exit 1
fi
[ -x "$BPFTRACE" ] || BPFTRACE="$S/bin/squashfs-root/AppRun"
[ -x "$BPFTRACE" ] || BPFTRACE="$S/bin/bpftrace-new"
[ -x "$BPFTRACE" ] || BPFTRACE="$(command -v bpftrace || true)"

# trace.bt uses strncmp(), uptr() and args.* on syscall tracepoints; older
# releases fail to compile it and the failure reads as "tracer died".
check_bpftrace_version() {
    local v major minor
    v=$("$BPFTRACE" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+' | head -1)
    [ -n "$v" ] || { echo "cannot determine bpftrace version at $BPFTRACE" >&2; exit 1; }
    major=${v#v}; major=${major%%.*}
    minor=${v##*.}
    if [ "$major" -eq 0 ] && [ "$minor" -lt 26 ]; then
        echo "bpftrace $v at $BPFTRACE is too old, 0.26 or newer is required" >&2
        echo "set SVP_BPFTRACE in config.local" >&2
        exit 1
    fi
}
BASE_PORT="${SVP_BASE_PORT:-27000}"

# open, write, read, connect, exec, unlink
DENOM_LINES=6

TAP="${SVP_TAP:-svptap0}"
HOST_IP="${SVP_HOST_IP:-172.16.77.1}"
GUEST_IP="${SVP_GUEST_IP:-172.16.77.2}"

tap_up() {
    if ip link show "$TAP" > /dev/null 2>&1; then
        echo "$TAP already exists, refusing to touch an interface we do not own" >&2
        return 1
    fi
    if ip route 2>/dev/null | grep -q "${HOST_IP%.*}\."; then
        echo "${HOST_IP%.*}.0/24 is already routed on this host" >&2
        return 1
    fi
    ip tuntap add dev "$TAP" mode tap || return 1
    ip addr add "$HOST_IP/24" dev "$TAP" || return 1
    ip link set "$TAP" up || return 1
    TAP_OWNED=1
    return 0
}

tap_down() {
    # Only remove what we created; deleting by name would take out someone
    # else's interface.
    if [ "${TAP_OWNED:-0}" = "1" ]; then
        ip link del "$TAP" 2>/dev/null || true
        TAP_OWNED=0
    fi
}

mkdir -p "$OUT"
ln -sfn "$(basename "$OUT")" "$S/results/latest" 2>/dev/null || true

# Explicit cd: the inherited cwd may be unreadable for root (a user FUSE mount),
# and bpftrace then fails at chdir before attaching any probe.
cd "$S" || exit 1

TRACE_PID=""
LISTENER_PIDS=""
TAP_OWNED=0

clear_envs() {
    local e
    for e in "$@"; do
        rm -f "$OUT/$e"-*.trace "$OUT/$e"-*.trace.err "$OUT/$e"-*.truth \
              "$OUT/$e"-*.gen "$OUT/$e"-*.runid "$OUT/$e"-*.console \
              "$OUT/$e"-*.INVALID "$OUT/$e"-*.NOTRUTH "$OUT/$e"-*.NOEND \
              "$OUT/$e"-*.drops "$OUT/$e"-*.clock.begin "$OUT/$e"-*.clock.end \
              "$OUT/$e"-*.debugfs "$OUT/$e"-*.e2fsck "$OUT/$e"-*.virtiofsd \
              "$OUT/$e"-*.vmm
    done
}

# Random part plus time: a bare timestamp produces false matches in the trace.
new_runid() {
    printf '%s%s' "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')" "$(date +%s)"
}

start_listeners() {
    LISTENER_PIDS=""
    local p
    for p in $(seq $BASE_PORT $((BASE_PORT + 9))); do
        # All addresses: a VM guest arrives from the tap address, not loopback.
        timeout 300 nc -l -k 0.0.0.0 "$p" > /dev/null 2>&1 &
        LISTENER_PIDS="$LISTENER_PIDS $!"
    done
    sleep 0.4
}

stop_listeners() {
    local p
    for p in $LISTENER_PIDS; do
        kill "$p" 2>/dev/null || true
    done
    # Wait by pid: a bare wait would also wait for the live tracer.
    for p in $LISTENER_PIDS; do
        wait "$p" 2>/dev/null || true
    done
    LISTENER_PIDS=""
}

start_trace() {
    local tag=$1
    TRACE_OUT="$OUT/$tag.trace"
    TRACE_ERR="$OUT/$tag.trace.err"
    rm -f "$TRACE_OUT" "$TRACE_ERR"
    date +%s%N > "$OUT/$tag.clock.begin"
    # $$ inside sh is the pid bpftrace inherits through exec; the program needs
    # it to skip its own output.
    sh -c 'exec "$0" "$1" $$ "$2"' "$BPFTRACE" "$S/src/trace.bt" "$BASE_PORT" \
        > "$TRACE_OUT" 2> "$TRACE_ERR" &
    TRACE_PID=$!
    local i=0
    while [ $i -lt 300 ]; do
        if grep -q 'TRACE-READY' "$TRACE_OUT" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$TRACE_PID" 2>/dev/null; then
            echo "tracer died, see $TRACE_ERR" >&2
            head -5 "$TRACE_ERR" >&2
            return 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    # Killing it here matters: otherwise it keeps running attached to
    # raw_syscalls machine-wide and the next wait blocks forever.
    echo "tracer did not report readiness within 30s, killing" >&2
    kill -KILL "$TRACE_PID" 2>/dev/null || true
    wait "$TRACE_PID" 2>/dev/null || true
    return 1
}

stop_trace() {
    local tag=${1:-unknown}
    [ -n "$TRACE_PID" ] || return 0
    kill -INT "$TRACE_PID" 2>/dev/null || true
    local i=0
    while [ $i -lt 100 ] && kill -0 "$TRACE_PID" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$TRACE_PID" 2>/dev/null; then
        kill -KILL "$TRACE_PID" 2>/dev/null || true
        echo "END block did not run, liveness maps missing" > "$OUT/$tag.NOEND"
    fi
    wait "$TRACE_PID" 2>/dev/null || true
    date +%s%N > "$OUT/$tag.clock.end"
    TRACE_PID=""
    unmount_apprun
}

# AppRun mounts a tmpfs per start and unmounts only on clean exit; the tracer is
# killed by signal, so the mounts pile up.
unmount_apprun() {
    local m="$S/bin/squashfs-root/mountroot"
    local i=0
    while grep -q " $m " /proc/mounts 2>/dev/null && [ $i -lt 50 ]; do
        umount "$m" 2>/dev/null || break
        i=$((i + 1))
    done
}

report_drops() {
    local tag=$1
    {
        grep -hoE '(Lost [0-9]+ events|Total lost event count: [0-9]+)' \
            "$OUT/$tag.trace" "$OUT/$tag.trace.err" 2>/dev/null | tail -1
        # Addrspace mismatch is filtered deliberately: run/diag-write-probe.sh
        # shows the probe catches every event with it present. Other warnings
        # stay a signal.
        grep -h 'WARNING' "$OUT/$tag.trace" "$OUT/$tag.trace.err" 2>/dev/null |
            grep -v 'Addrspace mismatch' | sort -u
    } > "$OUT/$tag.drops"
    if [ -s "$OUT/$tag.drops" ]; then
        echo "  WARNING: $(head -1 "$OUT/$tag.drops")"
    fi
}

# A known operation performed on the host inside the observation window. Without
# it a zero is uninterpretable: it could mean either an isolating boundary or a
# dead tracer. Called twice, before and after the workload, so that a tracer
# dying mid-run is still caught. Its token carries the hostprobe suffix and is
# subtracted from guest marker counts.
host_probe() {
    local runid=$1
    local d=/var/tmp
    local f="$d/SVP-$runid-hostprobe.dat"
    local b="$d/SVP-$runid-hostprobe.bin"

    : > "$f"
    # Payload must start with the marker: the write probe matches on a prefix.
    printf 'SVP-%s-hostprobe-w\n' "$runid" > "$f"
    if [ -x "$S/bin/svp-target" ]; then
        cp "$S/bin/svp-target" "$b" 2>/dev/null && "$b" 2>/dev/null
        rm -f "$b"
    fi
    rm -f "$f"
}

# A zero in a column is only interpretable if the probe for that column is known
# to have been alive in this very window, so the gate is per operation type
# rather than a single non-zero count: three live probes and one dead one would
# otherwise pass and turn the dead one's column into a finding. connect is not
# in the list because the host probe issues no connect; its liveness rests on
# the self-test and on the host row.
PROBE_OPS="open write exec unlink"

check_host_probe() {
    local tag=$1 runid=$2 op seen="" missing=""

    for op in $PROBE_OPS; do
        if grep -qa " op=$op .*SVP-$runid-hostprobe" "$OUT/$tag.trace" 2>/dev/null; then
            seen="$seen$op "
        else
            missing="$missing$op "
        fi
    done

    {
        echo "alive: ${seen:-none}"
        echo "missing: ${missing:-none}"
    } > "$OUT/$tag.probe"

    if [ -n "$missing" ]; then
        echo "host probe silent for: $missing" > "$OUT/$tag.INVALID"
        echo "    host probe silent for: $missing discarding run"
        return 1
    fi
    return 0
}

check_denominators() {
    local tag=$1 src=$2
    [ -f "$src" ] || return 0
    local bad
    bad=$(grep '^denom ' "$src" 2>/dev/null | grep 'succeeded=0$' | cut -d' ' -f2 | tr '\n' ' ')
    if [ -n "$bad" ]; then
        echo "zero denominator: $bad" > "$OUT/$tag.INVALID"
        echo "  zero denominator for: $bad"
    fi
}

# Numbers are only as reproducible as the environment recorded next to them.
write_manifest() {
    local name=$1
    sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
    {
        echo "arm:          $name"
        echo "date:         $(date -uIseconds)"
        echo "commit:       $(git -C "$S" rev-parse --short HEAD 2>/dev/null || echo unknown)$([ -n "$(git -C "$S" status --porcelain 2>/dev/null)" ] && echo -dirty)"
        echo "host kernel:  $(uname -srmo)"
        echo "distro:       $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "cpu:          $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
        echo "kvm:          $([ -r /dev/kvm ] && echo available || echo absent)"
        echo "gcc:          $(gcc --version 2>/dev/null | head -1)"
        echo "REPS:         ${REPS:-?}"
        echo "base port:    $BASE_PORT"
        echo "dest ip:      ${DEST_IP:-$HOST_IP}   tap: $TAP"
        echo "bpftrace:     $("$BPFTRACE" --version 2>&1 | head -1) [$BPFTRACE]"
        echo "  sha256:     $(sha "$BPFTRACE")"
        echo "trace.bt:     $(sha "$S/src/trace.bt")"
        echo "gen:          $(sha "$S/bin/gen")"
        echo "vminit:       $(sha "$S/bin/vminit")"
        echo "probecheck:   $(sha "$S/bin/probecheck")"
        if [ -n "${RUNSC:-}" ] && [ -x "${RUNSC:-}" ]; then
            echo "runsc:        $("$RUNSC" --version 2>&1 | head -1) [$RUNSC]"
            echo "  sha256:     $(sha "$RUNSC")"
        fi
        if [ -n "${QEMU:-}" ] && [ -x "${QEMU:-}" ]; then
            echo "qemu:         $("$QEMU" --version 2>&1 | head -1) [$QEMU]"
            echo "virtiofsd:    $("${VIRTIOFSD:-/nonexistent}" --version 2>&1 | head -1)"
            echo "firecracker:  $("${FC:-/nonexistent}" --version 2>&1 | head -1)"
            echo "guest kernel: ${KERNEL_SRC:-}"
            echo "  sha256:     $(sha "${KERNEL_SRC:-}")"
        fi
    } > "$OUT/manifest-$name.txt"
    cat "$OUT/manifest-$name.txt"
}
