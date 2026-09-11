#!/bin/bash
# Вторая рука: виртуальные машины. qemu с общим каталогом через virtiofsd,
# qemu с блочным корнем, firecracker с блочным корнем.
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo $0" >&2
    exit 1
fi

REPS="${REPS:-5}"
# Путь к распакованной сборке kata-static. Переопределяется переменной SVP_KATA.
KATA="${SVP_KATA:-$S/bin/kata/opt/kata}"
KERNEL_SRC="$KATA/share/kata-containers/vmlinux-6.18.35-202"
QEMU="$KATA/bin/qemu-system-x86_64"
VIRTIOFSD="$KATA/libexec/virtiofsd"
FC="$S/bin/firecracker"
VMWORK=/var/tmp/svp-vm

[ -r "$KERNEL_SRC" ] || { echo "нет гостевого ядра: $KERNEL_SRC" >&2; exit 1; }
[ -x "$QEMU" ] || QEMU=$(command -v qemu-system-x86_64)

# Ключевая правка разбора: токен прогона зашит в имена, которые обязан открыть
# сам монитор виртуальной машины. Тогда у строки, где ожидается ноль, появляется
# собственное доказательство живости трассировщика. Ноль маркеров гостя при
# наличии маркера образа означает границу; ноль и там, и там означает сломанную
# обвязку. Различить эти два случая в первом заходе было нечем, а на них стояли
# оба главных вывода.
build_images() {
    local runid=$1 shared=$2
    rm -rf "$VMWORK"
    mkdir -p "$VMWORK/stage/bin" "$VMWORK/stage/proc" "$VMWORK/stage/sys" \
             "$VMWORK/stage/dev" "$VMWORK/stage/work" "$VMWORK/shared"
    cp "$S/bin/vminit" "$VMWORK/stage/init"
    cp "$S/bin/gen" "$S/bin/svp-target" "$VMWORK/stage/bin/"

    KERNEL="$VMWORK/vmlinux-SVP-$runid"
    IMG="$VMWORK/disk-SVP-$runid.img"
    cp "$KERNEL_SRC" "$KERNEL"
    mke2fs -q -t ext4 -b 4096 -d "$VMWORK/stage" "$IMG" 256M

    if [ "$shared" = "yes" ]; then
        cp "$S/bin/gen" "$S/bin/svp-target" "$VMWORK/shared/"
        chmod -R 0777 "$VMWORK/shared"
    fi
}

# Способ выключения у мониторов разный. qemu понимает тройную ошибку, а
# firecracker её не поддерживает и остаётся висеть до таймаута уже после того,
# как гость всё отработал.
APPEND_QEMU="console=ttyS0 reboot=t panic=1 loglevel=4 init=/init"
APPEND_FC="console=ttyS0 reboot=k panic=1 loglevel=4 init=/init"

# qemu из бандла Kata собран без сетевого бэкенда user, а firecracker поддерживает
# только tap. Один механизм на все строки обеих рук, иначе среды несравнимы по
# сети. tap_up и tap_down живут в common.sh, их использует и первая рука.
NET_ARGS="svp_addr=$HOST_IP svp_guestaddr=$GUEST_IP"

run_qemu_block() {
    local runid=$1 tag=$2
    timeout 180 "$QEMU" -M q35 -enable-kvm -cpu host -smp 2 -m 1024 \
        -kernel "$KERNEL" \
        -append "root=/dev/vda rw $APPEND_QEMU svp_runid=$runid svp_port=$BASE_PORT $NET_ARGS" \
        -drive file="$IMG",format=raw,if=none,id=root \
        -device virtio-blk-pci,drive=root \
        -netdev tap,id=n0,ifname="$TAP",script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -L "$KATA/share/kata-qemu/qemu" \
        -display none -monitor none -no-reboot \
        -serial "file:$OUT/$tag.console" < /dev/null
}

run_qemu_virtiofs() {
    local runid=$1 tag=$2
    local sock="$VMWORK/vfs.sock"
    "$VIRTIOFSD" --socket-path="$sock" --shared-dir="$VMWORK/shared" \
        --sandbox=none > "$OUT/$tag.virtiofsd" 2>&1 &
    local vpid=$!
    sleep 0.6
    if ! kill -0 "$vpid" 2>/dev/null; then
        echo "  virtiofsd не поднялся, см. $OUT/$tag.virtiofsd"
        return 1
    fi
    timeout 300 "$QEMU" -M q35 -enable-kvm -cpu host -smp 2 -m 1024 \
        -object memory-backend-file,id=mem,size=1024M,mem-path=/dev/shm,share=on \
        -numa node,memdev=mem \
        -kernel "$KERNEL" \
        -append "root=/dev/vda rw $APPEND_QEMU svp_runid=$runid svp_port=$BASE_PORT $NET_ARGS svp_share=yes" \
        -drive file="$IMG",format=raw,if=none,id=root \
        -device virtio-blk-pci,drive=root \
        -chardev socket,id=vfs,path="$sock" \
        -device vhost-user-fs-pci,chardev=vfs,tag=svpshare \
        -netdev tap,id=n0,ifname="$TAP",script=no,downscript=no \
        -device virtio-net-pci,netdev=n0 \
        -L "$KATA/share/kata-qemu/qemu" \
        -display none -monitor none -no-reboot \
        -serial "file:$OUT/$tag.console" < /dev/null
    # Код возврата надо снять сразу: раньше статусом функции становился статус
    # завершающего kill, поэтому строка virtiofs печаталась с «кодом 0» даже
    # когда qemu падал или упирался в таймаут.
    local rc=$?
    kill "$vpid" 2>/dev/null || true
    wait "$vpid" 2>/dev/null || true
    return $rc
}

run_firecracker() {
    local runid=$1 tag=$2
    local cfg="$VMWORK/fc.json"
    cat > "$cfg" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$KERNEL",
    "boot_args": "root=/dev/vda rw $APPEND_FC svp_runid=$runid svp_port=$BASE_PORT $NET_ARGS"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "$IMG",
      "is_root_device": true, "is_read_only": false }
  ],
  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": "$TAP" }
  ],
  "machine-config": { "vcpu_count": 2, "mem_size_mib": 1024 }
}
EOF
    # --api-sock вместе с --no-api заставляет firecracker поднять управляющий
    # сокет и ждать команд вместо загрузки: снаружи это выглядит как зависание.
    # Без timeout намеренно: под ним $! это pid обёртки, а SIGKILL обёртке
    # дочернему процессу не передаётся. Из-за этого прогоны оставляли живые
    # firecracker, державшие дескрипторы tap и удалённых образов. Ограничение по
    # времени даёт цикл ожидания ниже.
    "$FC" --no-api --config-file "$cfg" \
        > "$OUT/$tag.console" 2>&1 < /dev/null &
    local fpid=$!

    # firecracker не гасится ни reboot=t, ни reboot=k: гость доходит до конца, а
    # монитор висит до таймаута. Окно наблюдения тогда длиннее в шестьдесят раз,
    # чем у соседних строк, и объём постороннего шума с ним несравним.
    local i=0
    while [ $i -lt 600 ]; do
        if grep -qa 'GUEST-DONE' "$OUT/$tag.console" 2>/dev/null; then
            sleep 0.3
            break
        fi
        kill -0 "$fpid" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
    done
    kill -KILL "$fpid" 2>/dev/null || true
    wait "$fpid" 2>/dev/null || true
    grep -qa 'GUEST-DONE' "$OUT/$tag.console" 2>/dev/null
}

write_manifest "vms"
{
    echo "qemu: $("$QEMU" --version 2>&1 | head -1) [$QEMU]"
    echo "virtiofsd: $("$VIRTIOFSD" --version 2>&1 | head -1)"
    echo "firecracker: $("$FC" --version 2>&1 | head -1)"
    echo "гостевое ядро sha256: $(sha256sum "$KERNEL_SRC" | cut -d' ' -f1)"
    echo "адрес назначения: $HOST_IP, гость: $GUEST_IP, tap: $TAP"
} >> "$OUT/manifest-vms.txt"

echo "прогонов на среду: $REPS"
# Устройство поднимается перед каждым повтором, здесь только проверка, что имя
# и подсеть свободны.
if tap_up; then
    tap_down
else
    echo "не удалось поднять $TAP, сетевые колонки будут пустыми" >&2
fi
# Полная уборка на всех путях выхода. Прерванный прогон оставлял под /var/tmp
# десятки мегабайт образов, живой трассировщик под root и слушателей на десяти
# портах.
cleanup_arm2() {
    stop_trace "cleanup" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    tap_down
    unmount_apprun
    rm -rf "$VMWORK"
}
trap cleanup_arm2 EXIT INT TERM
echo

clear_envs qemu-block qemu-virtiofs firecracker-block

for env in qemu-block qemu-virtiofs firecracker-block; do
    echo "=== $env ==="
    for r in $(seq 1 "$REPS"); do
        runid=$(new_runid)
        tag="$env-$r"

        case "$env" in
        qemu-virtiofs) build_images "$runid" yes ;;
        *)             build_images "$runid" no  ;;
        esac

        start_listeners
        if ! start_trace "$tag"; then
            stop_listeners
            continue
        fi

        # Устройство пересоздаётся перед каждым повтором. qemu отпускает его
        # штатно, а firecracker добивается сигналом, и следующий повтор упирался
        # в «Resource busy»: два прогона из трёх пропадали.
        tap_down
        if ! tap_up; then
            echo "  повтор $r: tap не поднялся, пропускаю"
            stop_listeners
            continue
        fi

        host_probe "$runid"
        case "$env" in
        qemu-block)        run_qemu_block "$runid" "$tag" ;;
        qemu-virtiofs)     run_qemu_virtiofs "$runid" "$tag" ;;
        firecracker-block) run_firecracker "$runid" "$tag" ;;
        esac
        vm_rc=$?
        host_probe "$runid"

        sleep 1
        stop_trace "$tag"
        stop_listeners

        # Истина читается из образа после выключения машины, то есть вне окна
        # наблюдения и без участия хостовых данных: гостевая сторона никогда не
        # выводится из хостовой.
        if [ "$env" = "qemu-virtiofs" ]; then
            # При смонтированном общем каталоге гость работает на нём, и истина
            # лежит прямо на хосте.
            cp "$VMWORK/shared/truth.txt" "$OUT/$tag.truth" 2>/dev/null || true
        else
            # Журнал ext4 может быть не проигран, и свежая запись тогда не
            # читается: без этого истина молча оказывается пустой.
            e2fsck -p -f "$IMG" > "$OUT/$tag.e2fsck" 2>&1 || true
            debugfs -R "dump /work/truth.txt $OUT/$tag.truth" "$IMG" \
                > "$OUT/$tag.debugfs" 2>&1
        fi

        # Истина обязана содержать все шесть знаменателей. Иначе она частичная,
        # и полнота, посчитанная от неё, выглядит лучше настоящей.
        if [ "$(grep -c '^denom ' "$OUT/$tag.truth" 2>/dev/null; true)" != "6" ]; then
            rm -f "$OUT/$tag.truth"
            echo "истина неполная или недоступна" > "$OUT/$tag.NOTRUTH"
        fi
        echo "$runid" > "$OUT/$tag.runid"

        # grep -c возвращает 1 при нуле совпадений, поэтому || echo дописывал
        # второй ноль и ломал строку отчёта.
        # Консоль последовательного порта содержит управляющие байты, поэтому -a.
        guest_ok=$(grep -ca 'GUEST-DONE' "$OUT/$tag.console" 2>/dev/null; true)
        # Хостовая проба носит тот же префикс и попадала в счётчик действий
        # гостя: при не загрузившемся госте это давало уверенные четыре маркера.
        mk=$(grep -a "^EVT .*SVP-$runid-" "$OUT/$tag.trace" 2>/dev/null | grep -vc 'hostprobe'; true)
        # Маркер образа засчитывается только от самого монитора. Иначе в него
        # попадало эхо трассировщика, печатавшего ту же строку, и контроль
        # живости удваивал сам себя.
        # Имя вызова здесь open, openat или openat2: firecracker открывает образ
        # устаревшим open, и шаблон, требовавший openat, обнулял контроль
        # живости ровно в той строке, где он нужнее всего.
        vmm=$(grep -cE "^EVT [0-9]+ (qemu|firecracker|fc_)[^ ]* [0-9]+ open(at2?)? .*(disk-SVP-$runid|vmlinux-SVP-$runid)" \
            "$OUT/$tag.trace" 2>/dev/null; true)
        guest_ok=${guest_ok:-0}; mk=${mk:-0}; vmm=${vmm:-0}
        printf '  прогон %d: гость дошёл %s, маркеров гостя %s, маркеров образа %s (код %s)\n' \
            "$r" "$guest_ok" "$mk" "$vmm" "$vm_rc"

        probe=$(probe_seen "$tag" "$runid")
        if [ "${probe:-0}" = "0" ]; then
            echo "хостовая проба не видна: трассировщик недоказуем" > "$OUT/$tag.INVALID"
            echo "    хостовая проба не попала в трейс: строку не использовать"
        elif [ "$guest_ok" = "0" ]; then
            echo "гость не дошёл до GUEST-DONE" > "$OUT/$tag.INVALID"
            echo "    гость не дошёл до конца: строка не о границе, а об обвязке"
        fi

        check_denominators "$tag" "$OUT/$tag.truth"
        report_drops "$tag"
    done
    echo
done

rm -rf "$VMWORK"
echo "готово, результаты в $OUT"
