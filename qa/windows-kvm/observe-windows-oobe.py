"""Observe allow-listed progress over the disposable Windows guest's serial console."""

import json
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import time


REPORT_FIELDS = {
    "RWLAB_DESKTOP": ("explorer", "sessionId", "windowsVersion", "windowsCaption"),
    "RWLAB_TPM": ("getTpmAvailable", "tpmPresent", "tpmReady", "tpmManufacturer", "secureBoot", "virtualCardTool"),
    "RWLAB_CARD": (
        "attempted", "createdState", "readerVisible", "createExitCode", "destroyExitCode",
        "removed", "newPnpCount", "pnpCountBefore", "pcscBaselineUnknown",
        "pcscCountBefore", "pcscCountAfterCreate", "pcscCountAfterDestroy",
        "pcscBeforeHResult", "pcscAfterCreateHResult", "pcscAfterDestroyHResult",
        "serviceStatusBefore", "serviceStatusAfterCreate", "serviceStatusAfterDestroy",
    ),
    "RWLAB_FIT_RESULT": ("passed", "version", "scope", "growth", "candidateTested", "smartCardTested", "phase"),
    "RWLAB_COMPLETE": ("virtualCardRequested", "fitRequested"),
    "RWLAB_ERROR": ("category",),
}

FIT_STAGES = ("Initial", "Growth", "Shrink")
FIT_GEOMETRY = {"viewport": 2, "stage": 2, "frame": 4}
PCSC_SUCCESS = "0x00000000"
PCSC_NO_SERVICE = "0x8010001D"
PCSC_KNOWN_COUNTS = {PCSC_SUCCESS, "0x8010002E"}


def card_lifecycle_confirmed(card):
    if (
        card.get("readerVisible") is not True or card.get("removed") is not True
        or card.get("createExitCode") != 0 or card.get("destroyExitCode") != 0
        or card.get("newPnpCount") != 1 or card.get("pcscAfterCreateHResult") != PCSC_SUCCESS
    ):
        return False
    before = card.get("pcscCountBefore")
    after_create = card.get("pcscCountAfterCreate")
    after_destroy = card.get("pcscCountAfterDestroy")
    after_destroy_status = card.get("pcscAfterDestroyHResult")
    if type(after_create) is not int:
        return False
    if card.get("pcscBaselineUnknown") is True:
        return (
            before is None and card.get("pcscBeforeHResult") == PCSC_NO_SERVICE
            and card.get("pnpCountBefore") == 0 and after_create == 1
            and (
                (after_destroy is None and after_destroy_status == PCSC_NO_SERVICE)
                or (type(after_destroy) is int and after_destroy == 0 and after_destroy_status in PCSC_KNOWN_COUNTS)
            )
        )
    return (
        card.get("pcscBeforeHResult") in PCSC_KNOWN_COUNTS
        and type(before) is int and type(after_destroy) is int and before >= 0
        and after_create == before + 1 and after_destroy == before
        and after_destroy_status in PCSC_KNOWN_COUNTS
    )


def read_fit_measurements(report):
    measurements = report.get("measurements")
    if not isinstance(measurements, dict):
        return {}
    result = {}
    for stage in FIT_STAGES:
        record = measurements.get(stage)
        if not isinstance(record, dict):
            continue
        dimensions = {}
        for field, size in FIT_GEOMETRY.items():
            values = record.get(field)
            if isinstance(values, list) and len(values) == size and all(type(value) is int for value in values):
                dimensions[field] = values
        if len(dimensions) == len(FIT_GEOMETRY):
            result[stage] = dimensions
    return result


def console_state(monitor, screenshot):
    boot_probe = runpy.run_path(str(Path(__file__).with_name("observe-windows-kvm-boot.py")))
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(str(monitor))
            with connection.makefile("rwb", buffering=0) as qmp:
                qmp.readline()
                boot_probe["command"](qmp, "qmp_capabilities")
                boot_probe["command"](qmp, "screendump", {"filename": str(screenshot)})
        console_text = subprocess.run(
            ["tesseract", str(screenshot), "stdout", "--psm", "11"],
            capture_output=True, check=True, text=True, timeout=12,
        ).stdout
        if boot_probe["WINDOWS_PROMPT"].search(console_text):
            return "Windows setup or login prompt"
        return boot_probe["classify_display"](console_text)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        return "unavailable"
    finally:
        screenshot.unlink(missing_ok=True)


def observe(serial, monitor, screenshot):
    deadline = time.monotonic() + 480
    offset = 0
    observed = {}
    while time.monotonic() < deadline:
        if serial.exists():
            with serial.open("rb") as stream:
                stream.seek(offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    try:
                        report = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue
                    if not isinstance(report, dict) or report.get("kind") not in REPORT_FIELDS:
                        continue
                    kind = report["kind"]
                    details = {key: report[key] for key in REPORT_FIELDS[kind] if key in report}
                    if kind == "RWLAB_FIT_RESULT":
                        details["measurements"] = read_fit_measurements(report)
                    observed[kind] = details
                    print(f"{kind} {json.dumps(details, ensure_ascii=True)}", flush=True)
        if "RWLAB_ERROR" in observed:
            raise RuntimeError("The Windows first-logon probe reported an error")
        if "RWLAB_COMPLETE" in observed:
            break
        time.sleep(2)
    else:
        raise RuntimeError(f"Windows first-logon report timed out. Console state: {console_state(monitor, screenshot)}.")

    if not observed.get("RWLAB_DESKTOP", {}).get("explorer"):
        raise RuntimeError("The guest did not report an interactive Explorer desktop")
    tpm = observed.get("RWLAB_TPM", {})
    if not (tpm.get("tpmPresent") and tpm.get("tpmReady")):
        raise RuntimeError("Windows did not report a present and ready TPM")
    if observed["RWLAB_COMPLETE"].get("virtualCardRequested") and not card_lifecycle_confirmed(observed.get("RWLAB_CARD", {})):
        raise RuntimeError("Windows did not confirm both creation and removal of the disposable virtual reader")
    if observed["RWLAB_COMPLETE"].get("fitRequested") or "RWLAB_FIT_RESULT" in observed:
        fit = observed.get("RWLAB_FIT_RESULT", {})
        if fit.get("passed") is not True or fit.get("version") != "0.8.4.0" or len(fit["measurements"]) != len(FIT_STAGES):
            raise RuntimeError("The published 0.8.4 RDP fixture did not pass with three measured stages")
    print("PASS Windows first logon reached the desktop and detected a ready TPM.", flush=True)


if __name__ == "__main__":
    observe(*(Path(argument) for argument in sys.argv[1:]))
