"""Build the NoCloud seed for the isolated live RDP test."""

import base64
import io
import json
import os
from pathlib import Path
import sys

MARKER = r"""#!/usr/bin/python3
import re
import subprocess
import tkinter as tk

root = tk.Tk()
root.overrideredirect(True)
canvas = tk.Canvas(root, borderwidth=0, highlightthickness=0)
canvas.pack(fill="both", expand=True)
last_size = None


def paint():
    global last_size
    current = subprocess.run(["xrandr", "--current"], capture_output=True, text=True).stdout
    match = re.search(r"current (\d+) x (\d+)", current)
    if match:
        width, height = map(int, match.groups())
        if (width, height) != last_size:
            last_size = (width, height)
            root.geometry(f"{width}x{height}+0+0")
            canvas.delete("all")
            for (x, y, color) in [(0, 0, "#d52e29"), (1, 0, "#2db56b"),
                                  (0, 1, "#295bed"), (1, 1, "#ecc531")]:
                canvas.create_rectangle(
                    x * (width // 2), y * (height // 2),
                    width if x else width // 2, height if y else height // 2,
                    outline="", fill=color)
            canvas.create_text(width // 2, height // 2, fill="white",
                               text=f"RDP LAB {width}x{height}")
            with open("/var/log/rw-lab-display", "a", encoding="utf-8") as log:
                log.write(f"RDP_LAB_DISPLAY={width}x{height}\n")
    root.after(200, paint)


paint()
root.mainloop()
"""


def seed_iso(directory: Path, password: str) -> None:
    import pycdlib

    build_status = (
        "set -eu\n"
        "install -m 0644 /root/rdp-lab-server.pem /etc/xrdp/rdp-lab-cert.pem\n"
        "install -o xrdp -m 0400 /root/rdp-lab-server.key /etc/xrdp/rdp-lab-key.pem\n"
        "sed -i 's|^certificate=.*|certificate=/etc/xrdp/rdp-lab-cert.pem|' /etc/xrdp/xrdp.ini\n"
        "sed -i 's|^key_file=.*|key_file=/etc/xrdp/rdp-lab-key.pem|' /etc/xrdp/xrdp.ini\n"
        "sed -i 's/^security_layer=.*/security_layer=tls/' /etc/xrdp/xrdp.ini\n"
        "sed -i 's/^autorun=.*/autorun=Xorg/' /etc/xrdp/xrdp.ini\n"
        "printf '%s\\n' '#!/bin/sh' 'exec /usr/local/bin/rw-rdp-marker' >/etc/xrdp/startwm.sh\n"
        "chmod 755 /etc/xrdp/startwm.sh\n"
        "install -o rdplab -m 0600 /dev/null /var/log/rw-lab-display\n"
        "systemd-run --unit=rw-lab-marker /bin/sh -c "
        "'tail -n+1 -F /var/log/rw-lab-display >>/dev/ttyS0'\n"
        "systemctl restart xrdp-sesman xrdp\n"
        "ss -lnt | grep -E ':[3]389[[:space:]]' >/dev/null\n"
        "printf '%s\\n' RDP_LAB_READY >/dev/ttyS0\n"
    )

    config = {
        "hostname": "rdp-lab",
        "disable_root": True,
        "ssh_pwauth": False,
        "users": [{"name": "rdplab", "shell": "/bin/bash", "lock_passwd": False}],
        "chpasswd": {
            "expire": False,
            "users": [{"name": "rdplab", "password": password, "type": "text"}],
        },
        "package_update": True,
        "packages": ["xrdp", "xorgxrdp", "x11-xserver-utils", "python3-tk"],
        "write_files": [
            {"path": "/usr/local/bin/rw-rdp-marker", "permissions": "0755", "content": MARKER},
            {"path": "/root/rdp-lab-init", "permissions": "0700", "content": build_status},
            *[
                {
                    "path": f"/root/{name}",
                    "permissions": "0600",
                    "encoding": "b64",
                    "content": base64.b64encode((directory / name).read_bytes()).decode("ascii"),
                }
                for name in ("rdp-lab-server.pem", "rdp-lab-server.key")
            ],
        ],
        "runcmd": [["/root/rdp-lab-init"]],
    }
    image = pycdlib.PyCdlib()
    image.new(vol_ident="CIDATA", joliet=3, rock_ridge="1.09")
    try:
        files = {
            "meta-data": "instance-id: remote-workspace-rdp-lab\n",
            "user-data": "#cloud-config\n" + json.dumps(config),
        }
        for name, data in files.items():
            payload = data.encode()
            iso_name = name.split("-", 1)[0].upper()
            image.add_fp(
                io.BytesIO(payload), len(payload), iso_path=f"/{iso_name}.;1",
                rr_name=name, joliet_path=f"/{name}",
            )
        image.write(str(directory / "cidata.iso"))
    finally:
        image.close()


if __name__ == "__main__":
    sys.path.insert(0, sys.argv[2])
    seed_iso(Path(sys.argv[1]), os.environ["RW_LAB_GUEST_PASSWORD"])
