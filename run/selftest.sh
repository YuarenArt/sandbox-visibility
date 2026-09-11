#!/bin/bash
# Самопроверка наблюдателя с заранее известным ответом. Каждая проба обязана
# поймать свой вызов, сделанный напрямую через syscall().
#
# Нужна потому, что молчащая проба неотличима от изолирующей песочницы: за один
# день стенд трижды выдал уверенный ноль, означавший отсутствие пробы, а не
# отсутствие данных на хосте.
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo $0" >&2
    exit 1
fi

W=/var/tmp/svp-selftest
RUNID="selftest$$"

cleanup_selftest() {
    stop_trace "selftest" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    unmount_apprun
    rm -rf "$W"
}
trap cleanup_selftest EXIT INT TERM

rm -rf "$W"; mkdir -p "$W"
cp "$S/bin/probecheck" "$S/bin/svp-target" "$W/"

start_listeners
if ! start_trace "selftest"; then
    echo "трассировщик не поднялся" >&2
    exit 1
fi

( cd "$W" && ./probecheck "$RUNID" "$BASE_PORT" "$W/svp-target" ) > "$W/out" 2>&1

sleep 1
stop_trace "selftest"
stop_listeners

T="$OUT/selftest.trace"
fail=0

check() {
    local label=$1 pattern=$2
    local n
    n=$(grep -ca "$pattern" "$T" 2>/dev/null; true)
    if [ "${n:-0}" -gt 0 ]; then
        printf '  ок   %-12s %s\n' "$label" "событий ${n:-0}"
    else
        printf '  СБОЙ %-12s проба молчит, ноль в этой колонке ничего не значит\n' "$label"
        fail=$((fail + 1))
    fi
}

echo
echo "самопроверка проб (каждый вызов сделан напрямую через syscall)"
check open      "^EVT .* open op=open .*$RUNID-pc-open"
check openat    "^EVT .* openat op=open .*$RUNID-pc-openat"
check write     "^EVT .* write op=write .*$RUNID-pc-write"
check pwritev   "^EVT .* pwritev op=write .*$RUNID-pc-pwritev"
check pwrite64  "^EVT .* pwrite64 op=write .*$RUNID-pc-pwrite64"
check unlink    "^EVT .* unlink op=unlink .*$RUNID-pc-open"
check unlinkat  "^EVT .* unlinkat op=unlink .*$RUNID-pc-openat"
check connect   "^EVT .* connect op=connect"
check execve    "^EVT .* execve op=exec .*$RUNID-pc-exec"

echo
if [ "$fail" -gt 0 ]; then
    echo "проб не работает: $fail. Прогон не запускаю: колонки этих проб были бы"
    echo "нулевыми по причине, не связанной с песочницей."
    exit 1
fi
echo "все пробы ловят свои вызовы"
exit 0
