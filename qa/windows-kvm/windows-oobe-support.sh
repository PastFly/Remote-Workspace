# This module is sourced by the Windows KVM harness after creating the private lab directory.

prepare_windows_oobe() {
    local lab_directory=$1
    sudo -n apt-get install -y -qq --no-install-recommends genisoimage
    local -a options=()
    if [[ ${RW_LAB_TEST_VIRTUAL_CARD:-} == true ]]; then
        options+=(--virtual-card)
    fi
    if [[ -n ${RW_LAB_EXTRA_MEDIA:-} ]]; then
        options+=(--extra-media "$RW_LAB_EXTRA_MEDIA")
    fi
    python3 "$fixture_dir/prepare-windows-oobe.py" "$lab_directory/setup-media" "${options[@]}"
    genisoimage -quiet -iso-level 3 -J -R -V RWLAB \
        -o "$lab_directory/setup.iso" "$lab_directory/setup-media"

    if [[ ${RW_LAB_STAGE_PANTHER_ANSWER:-} == true ]]; then
        # This optional Windows Setup search location has priority over cached Panther
        # answers. Only the disposable QCOW2 overlay is written.
        sudo -n apt-get install -y -qq --no-install-recommends libguestfs-tools
        sudo -n env LIBGUESTFS_BACKEND=direct guestfish --rw -a "$lab_directory/system.qcow2" -i \
            <<EOF
mkdir-p /Windows/Panther/Unattend
upload $lab_directory/setup-media/Autounattend.xml /Windows/Panther/Unattend/Unattend.xml
EOF
    fi
    rm -rf -- "$lab_directory/setup-media"

    windows_oobe_qemu_args=(
        -smbios type=1,manufacturer=QEMU,product=RemoteWorkspaceSetupLab
        -drive "file=$lab_directory/setup.iso,format=raw,media=cdrom,readonly=on"
        -serial "file:$lab_directory/guest-serial.txt"
    )
}

observe_windows_oobe() {
    local lab_directory=$1
    python3 "$fixture_dir/observe-windows-oobe.py" "$lab_directory/guest-serial.txt" \
        "$lab_directory/monitor.sock" "$lab_directory/oobe-console.ppm"
}
