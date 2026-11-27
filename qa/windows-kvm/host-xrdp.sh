#!/usr/bin/env bash
# Source this on the disposable KVM host. Only the QEMU guestfwd rule can reach
# the listener from Windows. This script does not enable networking in the VM.

stage_published_fit_fixture() {
    local fixture_dir=$1 work_dir=$2 media_dir=$3
    local msi=Remote-Workspace-0.8.4-x64.msi
    curl -fLsS --proto '=https' --proto-redir '=https' --retry 3 --max-time 90 \
        "https://github.com/PastFly/Remote-Workspace/releases/download/v0.8.4/$msi" \
        -o "$media_dir/$msi"
    printf '%s  %s\n' '9dcdd34168ef211cdcd09fe0bbd1407ea3ce1b226b7fe0c6c0f3525898051fd8' "$media_dir/$msi" |
        sha256sum --check --status
    DOTNET_CLI_HOME="$work_dir/fit-cli" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
        dotnet build "$fixture_dir/LiveMstscFitSmoke.csproj" -c Release --nologo \
        -p:BaseIntermediateOutputPath="$work_dir/fit-obj/" --output "$work_dir/fit"
    cp -- "$work_dir/fit/LiveMstscFitSmoke.exe" "$fixture_dir/Run-RemoteWorkspaceFixture.ps1" "$media_dir/"
    start_host_xrdp "$work_dir" "$media_dir" "$fixture_dir/../prepare-xrdp-guest.py"
}

start_host_xrdp() {
    local work_dir=$1 media_dir=$2 guest_marker=$3
    if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted || ${RUNNER_OS:-} != Linux ]]; then
        echo 'The xrdp host fixture is limited to an isolated GitHub-hosted Linux runner.' >&2
        return 1
    fi
    if getent passwd rdplab >/dev/null || dpkg-query -W -f '${db:Status-Status}' xrdp 2>/dev/null | grep -qx installed; then
        echo 'Expected a fresh disposable xrdp host.' >&2
        return 1
    fi

    # Package postinstall must never open a listener on an external interface.
    sudo -n systemctl mask --runtime xrdp.service xrdp-sesman.service
    sudo -n apt-get install -y -qq --no-install-recommends \
        xrdp xorgxrdp xserver-xorg-core x11-xserver-utils xauth python3-tk netcat-openbsd
    sudo -n useradd --create-home --shell /bin/bash rdplab
    local password
    password="Aa9!$(openssl rand -hex 18)"
    printf '%s:%s\n' rdplab "$password" | sudo -n chpasswd
    printf '%s' "$password" > "$media_dir/rdp-password.txt"
    chmod 0600 "$media_dir/rdp-password.txt"
    unset password

    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 1 \
        -subj '/CN=Remote Workspace Disposable Lab CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$work_dir/ca.key" -out "$work_dir/ca.pem" > "$work_dir/openssl.log" 2>&1
    openssl req -new -nodes -newkey rsa:2048 -sha256 -subj '/CN=10.0.2.100' \
        -keyout "$work_dir/server.key" -out "$work_dir/server.csr" >> "$work_dir/openssl.log" 2>&1
    cat > "$work_dir/server.extensions" <<'OPENSSL'
subjectAltName=IP:10.0.2.100
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
OPENSSL
    openssl x509 -req -days 1 -sha256 -in "$work_dir/server.csr" -CA "$work_dir/ca.pem" \
        -CAkey "$work_dir/ca.key" -CAcreateserial -out "$work_dir/server.pem" \
        -extfile "$work_dir/server.extensions" >> "$work_dir/openssl.log" 2>&1
    openssl x509 -in "$work_dir/ca.pem" -outform DER -out "$media_dir/rdp-lab-root.cer"
    sudo -n install -o xrdp -g xrdp -m 0400 "$work_dir/server.key" /etc/xrdp/rw-lab.key
    sudo -n install -m 0644 "$work_dir/server.pem" /etc/xrdp/rw-lab.pem

    # Reuse the quadrants and timing contract of the existing isolated guest marker.
    python3 - "$guest_marker" "$work_dir/marker.py" <<'PY'
import ast
from pathlib import Path
import sys
src, dest = map(Path, sys.argv[1:])
for statement in ast.parse(src.read_text()).body:
    if isinstance(statement, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'MARKER' for target in statement.targets):
        dest.write_text(ast.literal_eval(statement.value))
        break
else:
    raise SystemExit('The shared lab marker is missing.')
PY
    sudo -n install -m 0755 "$work_dir/marker.py" /usr/local/bin/rw-rdp-marker
    sudo -n install -o rdplab -m 0600 /dev/null /var/log/rw-lab-display
    printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/rw-rdp-marker' | sudo -n tee /etc/xrdp/startwm.sh >/dev/null
    sudo -n sed -i \
        -e 's|^port=3389$|port=tcp://127.0.0.1:33890|' \
        -e 's/^security_layer=.*/security_layer=tls/' \
        -e 's/^autorun=.*/autorun=Xorg/' \
        -e 's|^certificate=.*|certificate=/etc/xrdp/rw-lab.pem|' \
        -e 's|^key_file=.*|key_file=/etc/xrdp/rw-lab.key|' \
        /etc/xrdp/xrdp.ini
    sudo -n grep -qx 'port=tcp://127.0.0.1:33890' /etc/xrdp/xrdp.ini

    sudo -n systemctl unmask --runtime xrdp.service xrdp-sesman.service
    sudo -n systemctl start xrdp.service
    local sockets
    sockets=$(ss -H -lnt 'sport = :3389 or sport = :33890' | awk '{print $4}')
    if [[ $sockets != 127.0.0.1:33890 ]]; then
        sudo -n systemctl stop xrdp.service xrdp-sesman.service
        echo 'The xrdp fixture did not bind exclusively to 127.0.0.1:33890.' >&2
        return 1
    fi
    echo 'Private xrdp fixture listening exclusively on the Linux host loopback.'
}

stop_host_xrdp() {
    sudo -n systemctl stop xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
}
