#!/bin/bash
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0" >&2
    exit 1
fi

REPS="${REPS:-3}"
RUNSC="${SVP_RUNSC:-$S/bin/runsc}"
[ -x "$RUNSC" ] || { echo "runsc not found, set SVP_RUNSC in config.local" >&2; exit 1; }

WORKROOT=/var/tmp/svp

cleanup_arm1() {
    stop_trace "cleanup" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    tap_down
    unmount_apprun
    rm -rf "$WORKROOT"
}
trap cleanup_arm1 EXIT
# Without the explicit exit, bash runs the handler and returns into the loop,
# continuing the remaining repetitions with a killed tracer.
trap 'cleanup_arm1; exit 130' INT TERM

# Same tap and same destination as the VM arm, otherwise this arm would measure
# loopback and the network column would not be comparable across rows.
if tap_up; then
    DEST_IP="$HOST_IP"
else
    DEST_IP=127.0.0.1
    echo "warning: no tap, this arm's network column is not comparable to the VM arm" >&2
fi

prep_work() {
    rm -rf "$WORKROOT"
    mkdir -p "$WORKROOT"
    cp "$S/bin/gen" "$S/bin/svp-target" "$WORKROOT/"
}

# The workload runs as uid 0 inside its own environment everywhere: runsc do
# gives it root in the sandbox and the VM guest is PID 1, so running the host row
# unprivileged would push a privilege difference into the measured numbers.
run_env() {
    local env=$1 runid=$2 tag=$3
    local gen="cd $WORKROOT && SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP"
    local flags="--network=host --ignore-cgroups"

    case "$env" in
    host)
        ( cd "$WORKROOT" && SVP_RUNID="$runid" ./gen /dev/stdout ./svp-target "$BASE_PORT" "$DEST_IP" ) \
            > "$OUT/$tag.gen" 2>&1
        ;;
    sham)
        "$RUNSC" $flags do -force-overlay=false \
            /bin/sh -c "cd $WORKROOT && SVP_NOOP=1 SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP" \
            > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-overlay)
        "$RUNSC" $flags do /bin/sh -c "$gen" > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-directfs)
        "$RUNSC" $flags do -force-overlay=false /bin/sh -c "$gen" > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-gofer)
        "$RUNSC" $flags --directfs=false do -force-overlay=false \
            /bin/sh -c "$gen" > "$OUT/$tag.gen" 2>&1
        ;;
    esac
}

check_bpftrace_version
write_manifest "host-and-gvisor"
echo "destination: $DEST_IP"
echo "repetitions per environment: $REPS"
echo

clear_envs host sham gvisor-overlay gvisor-directfs gvisor-gofer

for env in host sham gvisor-overlay gvisor-directfs gvisor-gofer; do
    echo "=== $env ==="
    for r in $(seq 1 "$REPS"); do
        runid=$(new_runid)
        tag="$env-$r"
        prep_work
        start_listeners
        if ! start_trace "$tag"; then
            stop_listeners
            continue
        fi
        host_probe "$runid"
        run_env "$env" "$runid" "$tag"
        host_probe "$runid"
        sleep 1
        stop_trace "$tag"
        stop_listeners
        echo "$runid" > "$OUT/$tag.runid"

        # Truth travels on stdout: a file written inside the sandbox never
        # reaches the host under the default overlay, and an empty file is
        # indistinguishable from an idle guest.
        grep -E '^(op=|denom |runid |connect |start |end |noop)' \
            "$OUT/$tag.gen" > "$OUT/$tag.truth" 2>/dev/null || true
        # Same completeness bar as the VM arm: a truncated truth would shrink
        # the denominator and make recall look better than it is.
        if [ "$(grep -c '^denom ' "$OUT/$tag.truth" 2>/dev/null; true)" != "$DENOM_LINES" ]; then
            rm -f "$OUT/$tag.truth"
            echo "truth incomplete or unavailable" > "$OUT/$tag.NOTRUTH"
        fi

        check_host_probe "$tag" "$runid" || true

        # grep -c prints 0 and returns 1 on no match, so the count is taken
        # without a || fallback. The host probe shares the run prefix and is
        # subtracted here.
        mk=$(grep -a "^EVT .*SVP-$runid-" "$OUT/$tag.trace" 2>/dev/null | grep -vc 'hostprobe'; true)
        conn=$(grep -ca '^EVT .* connect ' "$OUT/$tag.trace" 2>/dev/null; true)
        all=$(grep -ca '^EVT ' "$OUT/$tag.trace" 2>/dev/null; true)
        printf '  run %d: markers %s, connect %s, events total %s\n' \
            "$r" "${mk:-0}" "${conn:-0}" "${all:-0}"

        # sham has zero denominators by design, not by harness failure.
        [ "$env" = "sham" ] || check_denominators "$tag" "$OUT/$tag.gen"
        report_drops "$tag"
    done
    echo
done

rm -rf "$WORKROOT"
echo "done, results in $OUT"
