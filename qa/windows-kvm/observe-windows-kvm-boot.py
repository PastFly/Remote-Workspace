"""Confirm that the isolated Windows evaluation guest reaches a visible setup or logon screen."""

import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import time


WINDOWS_PROMPT = re.compile(
    r"administrator|sign in|ctrl.{0,10}alt.{0,12}delet"
    r"|customize.{0,20}settings|the user.s password must be changed"
    r"|windows server setup|microsoft software license terms"
    r"|time and currency format|keyboard or input method",
    re.IGNORECASE,
)


def command(channel, name, arguments=None):
    request = {"execute": name}
    if arguments:
        request["arguments"] = arguments
    channel.write(json.dumps(request).encode() + b"\n")
    while response := channel.readline():
        message = json.loads(response)
        if "error" in message:
            raise RuntimeError(f"QMP {name} failed: {message['error']}")
        if "return" in message:
            return message["return"]
    raise RuntimeError(f"QMP connection closed while handling {name}")


def observe(monitor: Path, output: Path) -> None:
    screenshot = output / "windows-server-console.ppm"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(15)
        connection.connect(str(monitor))
        with connection.makefile("rwb", buffering=0) as qmp:
            json.loads(qmp.readline())  # QMP greeting.
            command(qmp, "qmp_capabilities")
            if not command(qmp, "query-kvm")["enabled"]:
                raise RuntimeError("QEMU did not start with KVM acceleration")
            if not any(device["model"] == "tpm-tis" for device in command(qmp, "query-tpm")):
                raise RuntimeError("QEMU did not attach the requested TPM device")
            print("PASS QEMU reports KVM acceleration and an attached emulated TPM device.", flush=True)
            deadline = time.monotonic() + 360
            while time.monotonic() < deadline:
                command(qmp, "screendump", {"filename": str(screenshot)})
                text = subprocess.run(
                    ["tesseract", str(screenshot), "stdout", "--psm", "11"],
                    check=True, capture_output=True, text=True, timeout=12,
                ).stdout
                match = WINDOWS_PROMPT.search(text)
                if match:
                    print(f"PASS Windows evaluation console showed an OS setup or login prompt ({match[0]}).", flush=True)
                    return
                time.sleep(5)
    raise RuntimeError("No recognizable Windows setup or login screen appeared within six minutes")


if __name__ == "__main__":
    observe(Path(sys.argv[1]), Path(sys.argv[2]))
