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
WINDOWS_REGION_FIELDS = [re.compile(field, re.IGNORECASE) for field in (
    r"home country/region", r"preferred app language", r"keyboard layout",
)]
DISPLAY_STATES = [
    ("firmware-security-violation", r"security violation|access denied.*boot"),
    ("no-bootable-media", r"no bootable|no boot media|boot failed|failed to load boot"),
    ("uefi-shell", r"uefi interactive shell|mapping table|shell>"),
    ("windows-recovery", r"automatic repair|recovery environment|pc needs to be repaired"),
    ("windows-loading", r"getting ready|getting devices ready|just a moment|please wait"),
    ("firmware-menu", r"boot manager|device manager|boot maintenance manager|bdsdxe|seabios"),
]


def classify_display(text: str) -> str:
    for category, marker in DISPLAY_STATES:
        if re.search(marker, " ".join(text.split()), re.IGNORECASE):
            return category
    return "unrecognized-text" if text.strip() else "graphics-without-readable-text"


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
            previous_state = None
            text = ""
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
                if sum(bool(field.search(text)) for field in WINDOWS_REGION_FIELDS) >= 2:
                    print("PASS Windows evaluation console reached first-run region and language setup.", flush=True)
                    return
                state = classify_display(text)
                if state != previous_state:
                    print(f"Windows evaluation console state: {state}", flush=True)
                    previous_state = state
                time.sleep(5)
    excerpt = " ".join(text.split())[:240]
    raise RuntimeError(f"No Windows setup or login screen appeared. Last console state: {previous_state}. OCR: {excerpt!r}")


if __name__ == "__main__":
    observe(Path(sys.argv[1]), Path(sys.argv[2]))
