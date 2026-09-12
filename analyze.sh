#!/bin/bash
set -u

S="$(cd "$(dirname "$0")" && pwd)"
# Sessions write to results/<timestamp>; the bare default has to follow the
# symlink, otherwise this reads whatever old session sits directly in results/.
OUT="${1:-$S/results/latest}"

if [ ! -d "$OUT" ]; then
    echo "no results directory: $OUT" >&2
    exit 1
fi

envs="host sham gvisor-overlay gvisor-directfs gvisor-gofer qemu-block qemu-virtiofs firecracker-block"

# Must match REPS in src/gen.c and the listener port range in run/common.sh.
OPS_PER_RUN=10

stats() {
    sort -n | {
        vals=$(cat)
        n=$(echo "$vals" | grep -c .)
        if [ "$n" = "0" ]; then
            echo "no"
            return
        fi
        mn=$(echo "$vals" | head -1)
        mx=$(echo "$vals" | tail -1)
        md=$(echo "$vals" | sed -n "$(((n + 1) / 2))p")
        if [ "$mn" = "$mx" ]; then
            echo "$mn"
        else
            echo "$mn/$md/$mx"
        fi
    }
}

# A token is counted only when it appears in an event of its own operation.
# Matching the token anywhere in the trace conflates operations: open and unlink
# share one token by design, and the exec token also shows up as the openat
# argument of the copy that precedes execve.
recall_for() {
    local trace=$1 truth=$2 op=$3
    local seen=0 total=0 tok
    [ -f "$truth" ] || { echo ""; return; }
    while read -r tok; do
        [ -n "$tok" ] || continue
        total=$((total + 1))
        # -a is required: traces contain NUL bytes and grep would treat the
        # file as binary and print nothing.
        if grep -qa -- " op=$op .*$tok" "$trace" 2>/dev/null; then
            seen=$((seen + 1))
        fi
    done <<EOF
$(grep -a "^op=$op " "$truth" 2>/dev/null | grep -a ' rc=0\| rc=[1-9]' |
  grep -av 'tok=NOT-INSTRUMENTED' | sed 's/.*tok=//; s/ .*//' | sort -u)
EOF
    [ "$total" = "0" ] && { echo ""; return; }
    echo "$seen/$total"
}

# connect carries no textual token, so it is matched by destination port.
# Counted as distinct ports, not as events, to stay comparable with the other
# columns. Foreign traffic to the same port range would still be counted.
recall_connect() {
    local trace=$1 truth=$2
    local declared seen
    declared=$(grep -a '^denom connect ' "$truth" 2>/dev/null | sed 's/.*succeeded=//')
    [ -n "$declared" ] || { echo ""; return; }
    seen=$(grep -oa 'port=[0-9]*' "$trace" 2>/dev/null | sort -u | grep -c . || true)
    echo "${seen:-0}/$declared"
}

printf '%-18s %-9s %-9s %-9s %-9s %-9s %-9s\n' \
    env runs open write unlink exec connect
printf '%s\n' "------------------------------------------------------------------------"

for env in $envs; do
    reps=0; bad=0; partial=0
    o=""; w=""; u=""; e=""; c=""
    for f in "$OUT/$env"-*.runid; do
        [ -f "$f" ] || continue
        tag=$(basename "$f" .runid)
        reps=$((reps + 1))
        # A run without usable truth cannot be scored: its denominator is
        # unknown, so it is discarded rather than shown as an empty row.
        # NOEND means the tracer was killed before its END block ran, so the
        # liveness maps for that repetition do not exist.
        if [ -f "$OUT/$tag.INVALID" ] || [ -f "$OUT/$tag.NOTRUTH" ] ||
           [ -f "$OUT/$tag.NOEND" ]; then
            bad=$((bad + 1))
            continue
        fi
        tr="$OUT/$tag.trace"; th="$OUT/$tag.truth"
        # Without the trace every column would come out zero, which is exactly
        # the silent failure this stand exists to detect. Refuse instead.
        if [ ! -f "$tr" ]; then
            echo "no trace for $tag: raw traces are not published, rerun the" >&2
            echo "measurement to reproduce the numbers" >&2
            exit 2
        fi
        ro=$(recall_for "$tr" "$th" open)
        rw=$(recall_for "$tr" "$th" write)
        ru=$(recall_for "$tr" "$th" unlink)
        re=$(recall_for "$tr" "$th" exec)
        rc=$(recall_connect "$tr" "$th")
        # The denominator comes from the workload, so it is compared against
        # what the workload itself declared, not against a hardcoded ten. An
        # environment that performs no actions at all is the negative control,
        # not a partial run.
        for r in "$ro" "$rw" "$ru" "$re" "$rc"; do
            case "$r" in
            ""|0/0) ;;
            */"$OPS_PER_RUN") ;;
            *) partial=1 ;;
            esac
        done
        o="$o$(echo "$ro" | cut -d/ -f1)
"
        w="$w$(echo "$rw" | cut -d/ -f1)
"
        u="$u$(echo "$ru" | cut -d/ -f1)
"
        e="$e$(echo "$re" | cut -d/ -f1)
"
        c="$c$(echo "$rc" | cut -d/ -f1)
"
    done

    label="$env"
    [ "$bad" != "0" ] && label="$label*"
    [ "$partial" != "0" ] && label="$label!"

    if [ "$reps" = "0" ]; then
        printf '%-18s %-9s %s\n' "$env" "0/0" "no runs"
        continue
    fi
    printf '%-18s %-9s %-9s %-9s %-9s %-9s %-9s\n' "$label" \
        "$((reps - bad))/$reps" \
        "$(echo "$o" | grep . | stats)" \
        "$(echo "$w" | grep . | stats)" \
        "$(echo "$u" | grep . | stats)" \
        "$(echo "$e" | grep . | stats)" \
        "$(echo "$c" | grep . | stats)"
done

echo
echo "numbers: distinct operations of that type whose marker reached the host, out of ten performed"
echo "format min/median/max across repetitions; a single number means all repetitions agreed"
echo "a token counts only when it appears in an event of its own operation type"
echo "connect is matched by destination port, not by token"
echo "* some repetitions discarded, see *.INVALID and *.NOTRUTH"
echo "! numerator or denominator is not ten, see the run's .truth"
echo "read is not instrumented: the syscall argument is a descriptor, not a path"

n_invalid=$(ls "$OUT"/*.INVALID 2>/dev/null | wc -l)
n_notruth=$(ls "$OUT"/*.NOTRUTH 2>/dev/null | wc -l)
n_drops=$(grep -l . "$OUT"/*.drops 2>/dev/null | wc -l)
echo
echo "discarded: $n_invalid, no truth: $n_notruth, with drops or warnings: $n_drops"
