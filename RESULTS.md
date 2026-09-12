# What the host sees of workload actions inside a sandbox

Session of 2026-09-12: three repetitions per environment, 24 runs in total, none
discarded, every run produced a complete ground-truth record. The tracer
attached all 23 probes in every run and emitted no warnings and no ring-buffer
losses; the per-run `*.drops` files are all empty. Three repetitions are enough
to see whether a value is stable across runs and not enough to bound how often
it might differ.

Toolchain versions and checksums in `results/published/manifest-*.txt`, per-run
guest records in `*.truth`, name-free event counters distilled from each trace
in `*.counters`, summary in `summary.txt`, checksums of the lot in
`PROVENANCE.txt`. The raw traces themselves are not published: they are taken
machine-wide and carry the names of unrelated processes. `./publish.sh
results/<session>` assembles that directory, so what is published is a function
of a session rather than a hand-picked selection.

Host: Linux 6.8.0-138-generic, x86-64. Observer: bpftrace 0.26.0 on syscall
tracepoints. gVisor `release-20260831.0` driven through `runsc do`. Guest kernel
`vmlinux-6.18.35-202` from `kata-static-4.1.0`, with qemu 11.0.1 and virtiofsd
1.14 from the same bundle; firecracker 1.16.1. The same tap device and the same
destination address for every environment.

## Results

A cell counts distinct operations of that type whose marker reached the host,
out of ten performed. A token is only counted inside an event of its own
operation type.

| Environment | open | write | unlink | exec | connect |
|---|---|---|---|---|---|
| `host`: no sandbox | 10 | 10 | 10 | 10 | 10 |
| `sham`: negative control, sandbox with zero actions | no | no | no | no | 0 |
| `gvisor-overlay`: `runsc do`, overlay left on | 10 | **0** | **0** | **0** | 10 |
| `gvisor-directfs`: `runsc do -force-overlay=false` | 10 | 10 | 10 | **0** | 10 |
| `gvisor-gofer`: same, `--directfs=false` | 10 | 10 | 10 | **0** | 10 |
| `qemu-block`: root on virtio-blk | 0 | 0 | 0 | 0 | 0 |
| `qemu-virtiofs`: shared directory over virtiofsd | 10 | 10 | 10 | **0** | 0 |
| `firecracker-block`: root on virtio-blk | 0 | 0 | 0 | 0 | 0 |

Row names match the artifact prefixes in `results/published/`, so any cell can be
traced back to the run that produced it. The `sham` row carries no numbers
because it performed no operations: `no` means the workload declared none of
that type, so recall has no denominator, and the connect cell reads zero
observed out of zero declared. What the row shows is that a sandbox launched the
same way with an idle workload leaves no markers of its own for the other rows
to have inherited.

**Read every zero with its caveat.** A zero means the marker did not appear in a
host syscall-tracepoint event of that operation type. It does not mean the host
could not know. In the block rows the guest's own record is recovered from the
image afterwards with `debugfs`, by this very harness, so the bytes are on the
host; they just never appear as a syscall argument. Probes measure syscall
entry, not outcome: an event says the call was made with that argument, not that
it succeeded.

The zero is not the tracer sitting idle either. In the six block-row
repetitions the unfiltered counter recorded between 104477 and 148473 syscalls
inside the observation window, of which 4526 to 8372 were writes of the flavours
the probes cover; see `*.counters`. The marker columns are zero in the middle of
that traffic, not instead of it.

## What this shows

**What decides is the storage interface, not isolation strength.** The two qemu
rows run the same guest kernel, the same VMM, the same network, the same actions
and the same privileges; what changes is whether the filesystem is served by a
process on the host or by a driver inside the guest on top of a block device.
Ten out of ten against zero. In the file columns the microVM, which isolates more
strongly than gVisor, leaks exactly as much as `directfs` does.

The two rows are not a single-variable experiment in the strict sense: the
virtiofs row also adds a second host process, a file-backed shared memory
object, a NUMA node and a guest working directory on a different filesystem.
All of those follow from serving the filesystem from the host; none of them is
an independent knob that was turned.

**No sandbox measured here turns the guest's `execve` into a host `execve`.**
Under gVisor the binary is executed by the Sentry, in a VM by the guest kernel.
That is narrower than "execution is invisible": the executable is copied into
place first, and wherever a host process serves the filesystem that copy is
opened by name on the host, marker included. The `exec` column counts `execve`
and `execveat` events only, so those opens are not in it. A `runc` row, where the
guest `execve` is a host `execve`, is not measured here at all.

**Configuration changes the picture more than the choice of runtime does.** The
same `runsc` binary produces all three gVisor rows. With the overlay left on,
names cross the boundary and contents do not, because the upper layer has no
address on the host at all.

Do not read that row as "the gVisor default". `runsc do` describes itself as a
command for testing only, and `-force-overlay` is a flag of that command rather
than a runtime setting. Under containerd the runtime is driven through
`runsc run` against an OCI bundle, whose overlay default is a different medium.
The row is honest about `runsc do`; it says nothing about production gVisor.

**Filesystem and network activity divide the table along different lines, but
the split is a property of the backend, not of virtualisation.** The VM rows show
zero connect events while the guest connected successfully ten times in every
repetition: traffic leaves through a tap device, so the host never issues a
connect of its own. The same qemu with a user-space network backend would
terminate the guest's TCP in a host process and the column would read ten. In the
other direction, the gVisor rows were run with `--network=host`, which is not the
runtime's default; with its own network stack that column would collapse to zero
as well.

**Attribution to the process inside the sandbox is lost even where the action is
visible.** Events are attributed to the runtime's own helper processes: `exe`
(the Sentry) and `vring_worker` (a virtiofsd worker thread). Attribution to the
sandbox instance survives through the host pid, and would also survive through
the cgroup had this harness not disabled cgroup setup.

## Controls

- **Probe self-test.** `run/selftest.sh` issues twelve syscalls directly
  through `syscall()`, covering thirteen checks, and requires every probe to
  catch its own. The measurement does not start if any probe is silent, because
  a silent probe is indistinguishable from an isolating sandbox. The legacy
  `open` and `unlink` are exempt only where the architecture has no such
  syscall, and the exemption is granted by `probecheck`'s own report of which
  syscalls it issued rather than by the probe's silence: on x86-64 both exist,
  so a silent probe there is a defect and is reported as one.
- **Host probe inside the observation window.** Known operations with a marker,
  performed on the host itself before and after the workload: an open, a write
  whose payload starts with the marker, an exec of a marked copy, and an unlink.
  Liveness is checked per operation type and written to `*.probe`; if any of the
  four is silent, the repetition is discarded, since a single non-zero count
  would let three live probes cover for a dead fourth and turn its column into a
  finding. In all 24 published runs the four are alive. The connect probe has no
  such in-window evidence; its liveness rests on the self-test and on the host
  row.
- **Run marker in the image and kernel filenames.** The VMM has to open them, so
  rows where zero is the expected result carry their own liveness evidence.
  Recorded per run in `*.vmm`; a run with neither guest nor image markers is
  discarded.
- **Negative control.** The same sandbox and the same launch path with zero
  actions; it has its own run id. It covers one gVisor configuration, not the VM
  rows.
- **Denominator from the workload.** Recall is computed only over operations the
  guest completed successfully; each outcome is recorded with its `errno`.
- **Operation-aware matching.** A token counts only inside an event of its own
  operation type. Matching it anywhere in the trace conflates operations: open
  and unlink share one token by design, and the exec token also appears as the
  openat argument of the copy that precedes execve.

## What this testbed does not do

- Two observation channels out of six: syscall tracepoints and process
  lifecycle. No `/proc` walk, no inotify, no reading the image bytes as a
  measured channel, no runtime-owned export such as `runsc trace`.
- No `runc` row. gVisor is driven through `runsc do`, which its own help calls a
  testing command; a production runtime under containerd uses `runsc run` from
  an OCI bundle and does not carry this overlay.
- gVisor runs with `--network=host`. The default network stack was not measured
  and would collapse the connect column to zero.
- Detection latency is not computed. Both sides record timestamps, but the guest
  and host clocks have different bases and no anchoring is implemented.
- `read` is not instrumented: the syscall argument is a descriptor, not a path.
- The visible name is the trailing path component relative to a directory
  descriptor, not a full path.
- No real security tool was run. What is measured is an observer of our own on
  the same tracepoints, that is, a model of one possible implementation.
- Kata is not measured as a product: the guest kernel, qemu and virtiofsd come
  from its bundle, but without containerd, `kata-runtime` or the guest agent.
- One host kernel, one architecture, a machine with unrelated load.

## Reproducing

    cp config.example config.local   # set SVP_KATA and friends
    sudo ./run-all.sh 3
    sudo ./publish.sh results/latest

Rebuilds the binaries, runs the probe self-test, both arms and the summary.
Each session writes into `results/<UTC timestamp>/`; nothing is overwritten.
The second command rebuilds `results/published` from that session.
