#!/bin/bash
# Первая рука: хост как положительный контроль, пустой прогон как отрицательный,
# и три конфигурации gVisor, включая оверлей по умолчанию.
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo $0" >&2
    exit 1
fi

REPS="${REPS:-5}"
RUNSC="$S/bin/runsc"
[ -x "$RUNSC" ] || RUNSC="${SVP_RUNSC:-}"
[ -x "$RUNSC" ] || { echo "нет runsc" >&2; exit 1; }

WORKROOT=/var/tmp/svp

cleanup_arm1() {
    stop_trace "cleanup" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    tap_down
    unmount_apprun
    rm -rf "$WORKROOT"
}
trap cleanup_arm1 EXIT INT TERM

# Тот же tap и тот же адрес назначения, что и во второй руке.
if tap_up; then
    DEST_IP="$HOST_IP"
else
    DEST_IP=127.0.0.1
    echo "внимание: tap не поднят, сетевая колонка этой руки несравнима с рукой ВМ" >&2
fi

prep_work() {
    rm -rf "$WORKROOT"
    mkdir -p "$WORKROOT"
    cp "$S/bin/gen" "$S/bin/svp-target" "$WORKROOT/"
}

# Нагрузка везде работает от uid 0 внутри своей среды. Иначе строки несравнимы:
# runsc do даёт нагрузке root внутри песочницы, в виртуальной машине генератор
# стартует как PID 1, и один только хост шёл бы от обычного пользователя. Исход
# unlink в каталоге со sticky-битом, connect на привилегированный порт и execve
# зависят от прав, то есть различие ушло бы прямо в измеряемые числа.
run_env() {
    local env=$1 runid=$2 tag=$3
    case "$env" in
    host)
        ( cd "$WORKROOT" && SVP_RUNID="$runid" ./gen /dev/stdout ./svp-target "$BASE_PORT" "$DEST_IP" ) \
            > "$OUT/$tag.gen" 2>&1
        ;;
    sham)
        # Та же песочница, тот же путь запуска, тот же идентификатор, ноль
        # действий. Ненулевые маркеры здесь означают ошибку отбора, а не
        # свойство среды.
        "$RUNSC" --network=host --ignore-cgroups do -force-overlay=false \
            /bin/sh -c "cd $WORKROOT && SVP_NOOP=1 SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP" \
            > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-overlay)
        "$RUNSC" --network=host --ignore-cgroups do \
            /bin/sh -c "cd $WORKROOT && SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP" \
            > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-directfs)
        "$RUNSC" --network=host --ignore-cgroups do -force-overlay=false \
            /bin/sh -c "cd $WORKROOT && SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP" \
            > "$OUT/$tag.gen" 2>&1
        ;;
    gvisor-gofer)
        "$RUNSC" --network=host --ignore-cgroups --directfs=false do -force-overlay=false \
            /bin/sh -c "cd $WORKROOT && SVP_RUNID=$runid ./gen /dev/stdout ./svp-target $BASE_PORT $DEST_IP" \
            > "$OUT/$tag.gen" 2>&1
        ;;
    esac
}

write_manifest "host-and-gvisor"
echo "адрес назначения: $DEST_IP"
echo "прогонов на среду: $REPS"
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

        # Истина пишется генератором в стандартный вывод и приезжает в .gen.
        # Файл внутри песочницы не годится: в конфигурации gVisor с оверлеем по
        # умолчанию он до хоста не доходит, и на его месте молча оказывался
        # пустой файл, неотличимый от «гость ничего не сделал».
        grep -E '^(op=|denom |runid |connect |start |end |noop)' \
            "$OUT/$tag.gen" > "$OUT/$tag.truth" 2>/dev/null || true
        if [ ! -s "$OUT/$tag.truth" ]; then
            echo "истина недоступна" > "$OUT/$tag.NOTRUTH"
        fi

        probe=$(probe_seen "$tag" "$runid")
        if [ "${probe:-0}" = "0" ]; then
            echo "хостовая проба не видна: трассировщик недоказуем" > "$OUT/$tag.INVALID"
            echo "    хостовая проба не попала в трейс: строку не использовать"
        fi

        # grep -c при нуле совпадений печатает 0 и возвращает 1, поэтому
        # прежнее || echo 0 дописывало второй ноль ровно на нулевых строках,
        # то есть на отрицательном контроле.
        # Хостовая проба носит тот же префикс и попадала бы в счётчик действий
        # нагрузки, завышая его на четыре события в каждой строке.
        mk=$(grep -a "^EVT .*SVP-$runid-" "$OUT/$tag.trace" 2>/dev/null | grep -vc 'hostprobe'; true)
        conn=$(grep -ca '^EVT .* connect ' "$OUT/$tag.trace" 2>/dev/null; true)
        all=$(grep -ca '^EVT ' "$OUT/$tag.trace" 2>/dev/null; true)
        printf '  прогон %d: маркеров %s, connect %s, событий всего %s\n' \
            "$r" "${mk:-0}" "${conn:-0}" "${all:-0}"

        # У sham нулевые знаменатели это и есть его режим, а не отказ обвязки.
        [ "$env" = "sham" ] || check_denominators "$tag" "$OUT/$tag.gen"
        report_drops "$tag"
    done
    echo
done

rm -rf "$WORKROOT"
echo "готово, результаты в $OUT"
