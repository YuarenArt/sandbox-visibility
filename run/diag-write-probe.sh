#!/bin/bash
# Какая форма чтения буфера write не даёт WARNING про адресные пространства и при
# этом действительно читает пользовательскую память. Гадать нельзя: предупреждение
# может означать и безобидный шум, и систематически пустую колонку.
set -u

S="$(cd "$(dirname "$0")/.." && pwd)"
BPFTRACE="$S/bin/squashfs-root/AppRun"
W=/var/tmp/svp-diag

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo $0" >&2
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
/args.count > 4 && args.count < 4096 && $expr/
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
    printf '%-34s событий %-5s предупреждений %s\n' "$name" "${hits:-0}" "${warns:-0}"
}

echo "нужны: ненулевые события И ноль предупреждений"
echo
try 'str(args.buf, 4)'        'str(args.buf, 4) == "SVP-"'
try 'str(uptr(args.buf), 4)'  'str(uptr(args.buf), 4) == "SVP-"'
try 'strncmp(str(args.buf),4)' 'strncmp(str(args.buf, 8), "SVP-", 4) == 0'

rm -rf "$W"
