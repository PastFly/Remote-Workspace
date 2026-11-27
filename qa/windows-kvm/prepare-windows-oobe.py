"""Create private, disposable Windows Setup media contents for the KVM lab."""

import argparse
import os
from pathlib import Path
import secrets
import shutil
import xml.etree.ElementTree as ET


UNATTEND = "urn:schemas-microsoft-com:unattend"
WCM = "http://schemas.microsoft.com/WMIConfig/2002/State"
COMPONENT_ATTRIBUTES = {
    "processorArchitecture": "amd64",
    "publicKeyToken": "31bf3856ad364e35",
    "language": "neutral",
    "versionScope": "nonSxS",
}
LAUNCH_PROBE = (
    "powershell.exe -NoLogo -NoProfile -NonInteractive -Command \""
    "$disc = [System.IO.DriveInfo]::GetDrives() | Where-Object { "
    "$_.DriveType -eq 'CDRom' -and $_.IsReady -and $_.VolumeLabel -eq 'RWLAB' "
    "} | Select-Object -First 1; "
    "if (-not $disc) { throw 'The lab media was not found.' }; "
    "& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned "
    "-File (Join-Path $disc.Name 'Probe-WindowsLab.ps1')\""
)


def append(parent, tag, text=None, **attributes):
    element = ET.SubElement(parent, f"{{{UNATTEND}}}{tag}", attributes)
    element.text = text
    return element


def password_element(parent, tag, password):
    element = append(parent, tag)
    append(element, "Value", password)
    append(element, "PlainText", "true")


def answer_file(password):
    ET.register_namespace("", UNATTEND)
    ET.register_namespace("wcm", WCM)
    unattended = ET.Element(f"{{{UNATTEND}}}unattend")
    specialize = append(unattended, "settings", **{"pass": "specialize"})
    identity = append(specialize, "component", name="Microsoft-Windows-Shell-Setup", **COMPONENT_ATTRIBUTES)
    append(identity, "ComputerName", "RWLABWIN")

    settings = append(unattended, "settings", **{"pass": "oobeSystem"})
    international = append(
        settings, "component", name="Microsoft-Windows-International-Core", **COMPONENT_ATTRIBUTES
    )
    for setting in ("InputLocale", "SystemLocale", "UILanguage", "UserLocale"):
        append(international, setting, "en-US")

    shell = append(settings, "component", name="Microsoft-Windows-Shell-Setup", **COMPONENT_ATTRIBUTES)
    accounts = append(shell, "UserAccounts")
    password_element(accounts, "AdministratorPassword", password)

    autologon = append(shell, "AutoLogon")
    password_element(autologon, "Password", password)
    append(autologon, "Enabled", "true")
    append(autologon, "Username", "Administrator")
    append(autologon, "LogonCount", "1")

    oobe = append(shell, "OOBE")
    append(oobe, "HideEULAPage", "true")
    append(oobe, "HideOnlineAccountScreens", "true")
    append(oobe, "HideWirelessSetupInOOBE", "true")

    first_logon = append(shell, "FirstLogonCommands")
    command = append(first_logon, "SynchronousCommand", **{f"{{{WCM}}}action": "add"})
    append(command, "Order", "1")
    append(command, "Description", "Verify the disposable lab desktop and TPM")
    append(command, "CommandLine", LAUNCH_PROBE)
    return ET.ElementTree(unattended)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--virtual-card", action="store_true")
    parser.add_argument("--extra-media", type=Path)
    arguments = parser.parse_args()

    arguments.output.mkdir(mode=0o700)
    if arguments.extra_media:
        for entry in arguments.extra_media.iterdir():
            if entry.name.lower() in {"autounattend.xml", "probe-windowslab.ps1", "create.virtual.card"}:
                raise ValueError("Additional media must not replace Windows Setup or probe files.")
            if entry.is_symlink() or not entry.is_file():
                raise ValueError("Only regular fixture files belong on the setup disc.")
            shutil.copyfile(entry, arguments.output / entry.name)

    # PlainText in Windows Setup's schema is intentional. This random password exists
    # only inside the private throwaway media and is never returned or written to stdout.
    password = "Rw!8" + secrets.token_hex(24)
    destination = arguments.output / "Autounattend.xml"
    handle = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(handle, "wb") as output:
        tree = answer_file(password)
        ET.indent(tree)
        tree.write(output, encoding="utf-8", xml_declaration=True)

    probe = Path(__file__).with_name("Probe-WindowsLab.ps1")
    shutil.copyfile(probe, arguments.output / probe.name)
    if arguments.virtual_card:
        (arguments.output / "create.virtual.card").touch(mode=0o600)


if __name__ == "__main__":
    main()
