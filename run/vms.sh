#!/bin/bash
set -u

source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0" >&2
    exit 1
fi

REPS="${REPS:-3}"
KATA="${SVP_KATA:-$S/bin/kata/opt/kata}"
QEMU="${SVP_QEMU:-$KATA/bin/qemu-system-x86_64}"
VIRTIOFSD="${SVP_VIRTIOFSD:-$KATA/libexec/virtiofsd}"
FC="${SVP_FIRECRACKER:-$S/bin/firecracker}"
VMWORK=/var/tmp/svp-vm

# Glob rather than a pinned patch version: any kata-static build works.
KERNEL_SRC=$(ls "$KATA"/share/kata-containers/vmlinux-* 2>/dev/null |
             grep -v debug | head -1)

need() {
    [ -x "$1" ] || [ -r "$1" ] || {
        echo "missing $2: $1" >&2
        echo "set SVP_KATA to an unpacked kata-static tree, see README" >&2
        exit 1
    }
}
[ -n "$KERNEL_SRC" ] || { echo "no guest kernel under $KATA/share/kata-containers" >&2; exit 1; }
need "$KERNEL_SRC" "guest kernel"
need "$QEMU" qemu
need "$VIRTIOFSD" virtiofsd
need "$FC" firecracker

# The run id goes into the image and kernel filenames, which the VMM itself has
# to open. That gives rows where zero is expected their own liveness evidence.
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

# qemu powers off on triple fault, firecracker does not.
APPEND_QEMU="console=ttyS0 reboot=t panic=1 loglevel=4 init=/init"
APPEND_FC="console=ttyS0 reboot=k panic=1 loglevel=4 init=/init"

NET_ARGS="svp_addr=$HOST_IP svp_guestaddr=$GUEST_IP"

# open, write, read, connect, exec, unlink
DENOM_LINES=6

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
        echo "  virtiofsd failed to start, see $OUT/$tag.virtiofsd"
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
    # Capture the exit code immediately: otherwise the trailing kill becomes the
    # function's status and a failed qemu reports success.
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
    # No timeout(1) wrapper: $! would be the wrapper and its SIGKILL never
    # reaches firecracker, leaving a live VM holding the tap and a deleted image.
    "$FC" --no-api --config-file "$cfg" \
        > "$OUT/$tag.console" 2>&1 < /dev/null &
    local fpid=$!

    # firecracker ignores reboot=k, so wait for GUEST-DONE and kill it. Letting
    # it run to a timeout would make this row's observation window sixty times
    # longer than its neighbours', with incomparable background noise.
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

check_bpftrace_version
write_manifest "vms"

echo "repetitions per environment: $REPS"
# The device is recreated per repetition; this only checks the name and subnet
# are free before starting.
if tap_up; then
    tap_down
else
    echo "could not bring up $TAP, network columns will be empty" >&2
fi
cleanup_arm2() {
    stop_trace "cleanup" 2>/dev/null || true
    stop_listeners 2>/dev/null || true
    tap_down
    unmount_apprun
    rm -rf "$VMWORK"
}
trap cleanup_arm2 EXIT
trap 'cleanup_arm2; exit 130' INT TERM
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

        # Recreate the tap per repetition: firecracker is killed by signal and
        # leaves the device busy for the next run.
        tap_down
        if ! tap_up; then
            echo "  run $r: tap unavailable, skipping"
            stop_trace "$tag"
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

        # Truth is extracted after shutdown, outside the observation window: the
        # guest side is never derived from host data.
        if [ "$env" = "qemu-virtiofs" ]; then
            cp "$VMWORK/shared/truth.txt" "$OUT/$tag.truth" 2>/dev/null || true
        else
            # Replay the ext4 journal first, otherwise the freshly written truth
            # file is not readable.
            e2fsck -p -f "$IMG" > "$OUT/$tag.e2fsck" 2>&1 || true
            debugfs -R "dump /work/truth.txt $OUT/$tag.truth" "$IMG" \
                > "$OUT/$tag.debugfs" 2>&1
        fi

        # Truth must carry a denominator for every operation type; a partial one
        # would make recall look better than it is.
        if [ "$(grep -c '^denom ' "$OUT/$tag.truth" 2>/dev/null; true)" != "$DENOM_LINES" ]; then
            rm -f "$OUT/$tag.truth"
            echo "truth incomplete or unavailable" > "$OUT/$tag.NOTRUTH"
        fi
        echo "$runid" > "$OUT/$tag.runid"

        # The serial console carries control bytes, hence -a.
        guest_ok=$(grep -ca 'GUEST-DONE' "$OUT/$tag.console" 2>/dev/null; true)
        # The host probe shares the run prefix and is subtracted here.
        mk=$(grep -a "^EVT .*SVP-$runid-" "$OUT/$tag.trace" 2>/dev/null | grep -vc 'hostprobe'; true)
        # Count the image marker only from the VMM's own comm, otherwise the
        # tracer's echo of the same line counts itself. firecracker opens the
        # image with legacy open(), hence open/openat/openat2.
        vmm=$(grep -cE "^EVT [0-9]+ (qemu|firecracker|fc_)[^ ]* [0-9]+ open(at2?)? .*(disk-SVP-$runid|vmlinux-SVP-$runid)" \
            "$OUT/$tag.trace" 2>/dev/null; true)
        guest_ok=${guest_ok:-0}; mk=${mk:-0}; vmm=${vmm:-0}
        echo "$vmm" > "$OUT/$tag.vmm"
        share_ok=1
        if [ "$env" = "qemu-virtiofs" ]; then
            share_ok=$(grep -ca 'SHARE-MOUNTED' "$OUT/$tag.console" 2>/dev/null; true)
            share_ok=${share_ok:-0}
        fi
        printf '  run %d: guest done %s, guest markers %s, image markers %s (rc %s)\n' \
            "$r" "$guest_ok" "$mk" "$vmm" "$vm_rc"

        if ! check_host_probe "$tag" "$runid"; then
            :
        elif [ "$guest_ok" = "0" ]; then
            echo "guest never reached GUEST-DONE" > "$OUT/$tag.INVALID"
            echo "    guest did not finish, this is about the harness, not the boundary"
        elif [ "$share_ok" = "0" ]; then
            echo "shared directory not mounted in the guest" > "$OUT/$tag.INVALID"
            echo "    share not mounted: this would be a second block-root run"
        elif [ "$mk" = "0" ] && [ "$vmm" = "0" ]; then
            echo "zero with no in-row liveness evidence" > "$OUT/$tag.INVALID"
            echo "    neither guest nor image markers: harness unproven, discarding run"
        fi

        check_denominators "$tag" "$OUT/$tag.truth"
        report_drops "$tag"
    done
    echo
done

rm -rf "$VMWORK"
echo "done, results in $OUT"
