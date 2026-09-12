#!/bin/bash
# Which form of reading the write buffer both avoids the addrspace warning and
# actually reads user memory. Guessing is not an option: the warning can mean
# harmless noise or a systematically empty column.
set -u

S="$(cd "$(dirname "$0")/.." && pwd)"
# Same resolution order as common.sh: a diagnostic that picks a different
# bpftrace from the one the harness runs is diagnosing a different binary.
[ -r "$S/config.local" ] && . "$S/config.local"
BPFTRACE="${SVP_BPFTRACE:-}"
[ -x "$BPFTRACE" ] || BPFTRACE="$S/bin/squashfs-root/AppRun"
[ -x "$BPFTRACE" ] || BPFTRACE="$S/bin/bpftrace-new"
[ -x "$BPFTRACE" ] || BPFTRACE="$(command -v bpftrace || true)"
W=/var/tmp/svp-diag

[ -x "$BPFTRACE" ] || {
    echo "bpftrace not found at $BPFTRACE, set SVP_BPFTRACE in config.local" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0" >&2
    exit 1
fi

mkdir -p "$W"
cat > "$W/writer.sh" <<'EOF'
#!/bin/sh
i=0
while [ $i -lt 40 ]; do
    printf 'SVP-DIAGMARKER-%03d\n' "$i" > /dev/null
    printf 'SVP-DIAGMARKER-%03d\n' "$i" >> /var/tmp/svp-diag/out.txt
    i=$((i + 1))
    sleep 0.05
done
EOF
chmod +x "$W/writer.sh"

try() {
    local name=$1 expr=$2
    : > "$W/out.txt"
    "$BPFTRACE" -e "
tracepoint:syscalls:sys_enter_write
/args.count > 4 && $expr/
{ printf(\"HIT %s\n\", comm); }
" > "$W/$name.out" 2> "$W/$name.err" &
    local bp=$!
    sleep 4
    "$W/writer.sh" > /dev/null 2>&1
    sleep 1
    kill -INT "$bp" 2>/dev/null
    wait "$bp" 2>/dev/null

    local hits warns
    hits=$(grep -c '^HIT ' "$W/$name.out" 2>/dev/null; true)
    warns=$(grep -c 'WARNING' "$W/$name.out" "$W/$name.err" 2>/dev/null | \
            cut -d: -f2 | paste -sd+ | bc 2>/dev/null || echo 0)
    printf '%-34s events %-5s warnings %s\n' "$name" "${hits:-0}" "${warns:-0}"
}

echo "looking for: non-zero events AND zero warnings"
echo
try 'str(args.buf, 4)'        'str(args.buf, 4) == "SVP-"'
try 'str(uptr(args.buf), 4)'  'str(uptr(args.buf), 4) == "SVP-"'
try 'strncmp(str(args.buf),4)' 'strncmp(str(args.buf, 8), "SVP-", 4) == 0'

rm -rf "$W"
