#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ||
      ${RUNNER_OS:-} != Linux || $(uname -m) != x86_64 ]]; then
    echo "Use a disposable GitHub-hosted x64 Linux runner." >&2
    exit 1
fi

fixture_dir=$(cd "$(dirname "$0")" && pwd)
. "$fixture_dir/windows-oobe-support.sh"
lab=$(mktemp -d "$RUNNER_TEMP/rw-win-kvm.XXXXXX")
mkdir -p "$RUNNER_TEMP/rw-windows-boot-proof"
proof="$RUNNER_TEMP/rw-windows-boot-proof"

stop_guest() {
    if [[ -f "$lab/qemu.pid" ]]; then
        guest_pid=$(<"$lab/qemu.pid")
        if [[ $guest_pid =~ ^[1-9][0-9]*$ ]]; then
            kill "$guest_pid" 2>/dev/null || true
        fi
    fi
    if [[ -f "$lab/swtpm.pid" ]]; then
        emulator_pid=$(<"$lab/swtpm.pid")
        if [[ $emulator_pid =~ ^[1-9][0-9]*$ ]]; then
            kill "$emulator_pid" 2>/dev/null || true
        fi
    fi
    rm -rf -- "$lab"
}
trap stop_guest EXIT

sudo -n apt-get update -qq
sudo -n apt-get install -y -qq --no-install-recommends \
    qemu-system-x86 qemu-utils ovmf swtpm tesseract-ocr tesseract-ocr-eng

qemu_runner=()
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    kvm_gid=$(getent group kvm | cut -d: -f3)
    qemu_runner=(sudo -n setpriv --reuid "$(id -u)" --regid "$kvm_gid" --clear-groups --)
fi
"${qemu_runner[@]}" bash -c '[[ -r /dev/kvm && -w /dev/kvm ]]'

disk_size=11686379520
available=$(df --output=avail -B1 "$lab" | tail -n 1)
if (( available < disk_size + 2000000000 )); then
    echo "Insufficient disk space for the verified evaluation image and its boot overlay." >&2
    exit 1
fi

disk="$lab/windows-server-2025-eval.vhdx"
curl -fLsS --proto '=https' --proto-redir '=https' --retry 3 --max-time 900 \
    https://aka.ms/WinServ2025vhd-enus -o "$disk"
[[ $(stat -c '%s' "$disk") -eq $disk_size ]]
# Independent file catalog digest of this exact Microsoft CDN image.
printf '%s  %s\n' '2d175924c8e647969a82e36f931b22397108bd94a030e0e947b7e66e47e0be9a' "$disk" |
    sha256sum --check --status
echo "Microsoft evaluation VHDX length and pinned SHA-256 verified."
chmod a-w "$disk"

qemu-img create -q -f qcow2 -F vhdx -b "$disk" "$lab/system.qcow2"
prepare_windows_oobe "$lab"
qemu-img dd -f vhdx -O raw bs=512 count=16 "if=$disk" "of=$lab/partition-head.bin"
partition_style=$(python3 - "$lab/partition-head.bin" <<'PY'
from pathlib import Path
import sys
head = Path(sys.argv[1]).read_bytes()
if any(head[offset:offset + 8] == b"EFI PART" for offset in (512, 4096)):
    print("gpt")
elif head[510:512] == b"\x55\xaa" and any(head[offset] for offset in (450, 466, 482, 498)):
    print("mbr")
else:
    sys.exit("The Windows evaluation disk has no recognized GPT or MBR.")
PY
)
echo "Windows evaluation image partition style: $partition_style."
if [[ $partition_style == gpt ]]; then
    ovmf_code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
    ovmf_vars=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
    [[ -f $ovmf_code && -f $ovmf_vars ]]
    if [[ ${RW_LAB_EFI_BOOT_RECOVERY:-} == true ]]; then
        sudo -n apt-get install -y -qq --no-install-recommends python3-virt-firmware
        virt-fw-vars -i "$ovmf_vars" -o "$lab/OVMF_VARS.fd" \
            --append-boot-filepath '\EFI\Microsoft\Boot\bootmgfw.efi'
        echo "Added the standard Windows Boot Manager path to the disposable EFI variables."
    else
        cp -- "$ovmf_vars" "$lab/OVMF_VARS.fd"
    fi
    firmware=(
        -global driver=cfi.pflash01,property=secure,value=on
        -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
        -drive "if=pflash,format=raw,file=$lab/OVMF_VARS.fd"
    )
else
    # QEMU's standard BIOS matches an evaluation image authored for Hyper-V generation 1.
    firmware=()
fi

mkdir -m 700 "$lab/tpm"
swtpm socket --tpm2 --tpmstate "dir=$lab/tpm" \
    --ctrl "type=unixio,path=$lab/tpm.sock" --pid "file=$lab/swtpm.pid" \
    --log "file=$lab/swtpm.log,level=2" --terminate --daemon
[[ -S "$lab/tpm.sock" ]]

"${qemu_runner[@]}" qemu-system-x86_64 \
    -machine q35,accel=kvm,smm=on -cpu host -smp 4 -m 6144 \
    -display none -vga std -monitor none -nic none \
    "${firmware[@]}" "${windows_oobe_qemu_args[@]}" \
    -drive "file=$lab/system.qcow2,format=qcow2,if=ide" \
    -chardev "socket,id=labtpm,path=$lab/tpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=labtpm -device tpm-tis,tpmdev=tpm0 \
    -qmp "unix:$lab/monitor.sock,server=on,wait=off" \
    -boot order=c -pidfile "$lab/qemu.pid" -daemonize

observe_windows_oobe "$lab"
