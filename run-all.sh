#!/bin/bash
# Всё за один запуск: самопроверка проб, обе руки, сводка.
# Один пароль вместо четырёх.
set -u

S="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo $0 [REPS]" >&2
    exit 1
fi

export REPS="${1:-${REPS:-1}}"

echo "############ пересборка ############"
gcc -O2 -static -o "$S/bin/gen" "$S/src/gen.c" || exit 1
gcc -O2 -static -o "$S/bin/vminit" "$S/src/vminit.c" || exit 1
gcc -O2 -static -o "$S/bin/svp-target" "$S/src/target.c" || exit 1
gcc -O2 -static -o "$S/bin/probecheck" "$S/src/probecheck.c" || exit 1
echo "собрано"

echo
echo "############ самопроверка проб ############"
# Прогон без рабочих проб бессмысленен: их колонки будут нулевыми по причине,
# не связанной с песочницей, и это неотличимо от результата.
if ! "$S/run/selftest.sh"; then
    echo
    echo "прогон отменён" >&2
    exit 1
fi

echo
echo "############ рука 1: хост и gVisor ############"
"$S/run/host-and-gvisor.sh" || echo "рука 1 завершилась с ошибкой" >&2

echo
echo "############ рука 2: виртуальные машины ############"
"$S/run/vms.sh" || echo "рука 2 завершилась с ошибкой" >&2

echo
echo "############ сводка ############"
"$S/analyze.sh"

# Результаты пишутся из-под root, иначе их не прочитать без sudo.
chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$S/results" 2>/dev/null || true
