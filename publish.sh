#!/bin/bash
# Assembles results/published from one session directory. Raw traces stay out:
# they are taken machine-wide and carry the names of unrelated processes. What
# goes in is what the table can be audited against, plus name-free aggregates
# distilled from the traces.
set -eu

S="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$S/results/latest}"
DST="$S/results/published"

[ -d "$SRC" ] || { echo "no such session: $SRC" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd)"

# Distils one trace into the counters the claims rest on. The liveness and
# write-family maps are keyed by process name, so only aggregates survive: the
# point is "the tracer saw tens of thousands of events", not whose they were.
counters() {
    local trace=$1
    grep -a '^TRACE-END\|^@n_' "$trace" 2>/dev/null || true
    awk '
        /^@liveness_all_by_comm\[/ { n = $NF; lt += n; lc++ }
        /^@wr_family\[/ { split($0, p, ", "); split(p[2], q, "]"); f[q[1]] += $NF }
        END {
            printf "liveness_events_total: %d\n", lt
            printf "liveness_distinct_comms: %d\n", lc
            for (k in f) printf "write_family_total[%s]: %d\n", k, f[k]
        }
    ' "$trace"
}

rm -rf "$DST"
mkdir -p "$DST"

for f in "$SRC"/*.runid "$SRC"/*.truth "$SRC"/*.vmm "$SRC"/*.drops \
         "$SRC"/*.probe "$SRC"/selftest.probecheck \
         "$SRC"/manifest-*.txt "$SRC"/*.INVALID "$SRC"/*.NOTRUTH "$SRC"/*.NOEND; do
    [ -f "$f" ] || continue
    cp "$f" "$DST/"
done

for t in "$SRC"/*.trace; do
    [ -f "$t" ] || continue
    counters "$t" > "$DST/$(basename "$t" .trace).counters"
done

"$S/analyze.sh" "$SRC" > "$DST/summary.txt"

# Checksums are taken before PROVENANCE.txt exists, so the file never has to
# hash itself.
sums=$(cd "$DST" && sha256sum -- * | sort -k2)
{
    echo "session: $(basename "$SRC")"
    echo "assembled by: publish.sh"
    echo
    echo "raw traces are not published: machine-wide capture, unrelated process names"
    echo "*.counters are name-free aggregates distilled from those traces"
    echo
    echo "$sums"
} > "$DST/PROVENANCE.txt"

chmod -R a+r "$DST"
# The session is written under sudo, so without this the published copy lands in
# the working tree owned by root and the next commit needs sudo too.
chown -R "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$DST" 2>/dev/null || true
echo "published $(ls "$DST" | wc -l) files from $(basename "$SRC")"
