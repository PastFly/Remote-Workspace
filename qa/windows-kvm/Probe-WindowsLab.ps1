Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$disc = [System.IO.DriveInfo]::new($PSScriptRoot)
$computer = Get-CimInstance Win32_ComputerSystem
if ($disc.DriveType -ne 'CDRom' -or $disc.VolumeLabel -ne 'RWLAB' -or
    $computer.Manufacturer -ne 'QEMU' -or $computer.Model -ne 'RemoteWorkspaceSetupLab') {
    throw 'The probe is scoped to the disposable Windows Setup virtual machine.'
}

$serial = [System.IO.Ports.SerialPort]::new('COM1', 115200)
$serial.NewLine = [string][char]10
$serial.WriteTimeout = 5000
$serial.Open()

$report = {
    param([string] $Kind, [hashtable] $Details)
    $record = [ordered] @{ kind = $Kind }
    foreach ($entry in $Details.GetEnumerator()) {
        $record[$entry.Key] = $entry.Value
    }
    $serial.WriteLine(($record | ConvertTo-Json -Compress -Depth 4))
}.GetNewClosure()

function Invoke-LabCardCommand([string] $CardTool, [string] $Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new($CardTool, $Arguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $command = [Diagnostics.Process]::Start($startInfo)
    try {
        $output = $command.StandardOutput.ReadToEndAsync()
        $errorOutput = $command.StandardError.ReadToEndAsync()
        if (-not $command.WaitForExit(60000)) {
            $command.Kill()
            return @{ exitCode = -1; output = '' }
        }
        $null = $errorOutput.GetAwaiter().GetResult()
        return @{ exitCode = $command.ExitCode; output = $output.GetAwaiter().GetResult() }
    }
    finally {
        $command.Dispose()
    }
}

try {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    # Windows Setup's LogonCount=1 has a documented off-by-one behavior.
    New-ItemProperty -Path $winlogon -Name AutoLogonCount -PropertyType DWord -Value 0 -Force | Out-Null
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue

    $current = Get-Process -Id $PID
    $deadline = (Get-Date).AddSeconds(50)
    do {
        $explorer = @(
            Get-Process -Name explorer -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $current.SessionId -and $_.SessionId -gt 0 }
        )
        if ($explorer.Count -gt 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $os = Get-CimInstance Win32_OperatingSystem
    & $report 'RWLAB_DESKTOP' @{
        explorer = $explorer.Count -gt 0
        sessionId = $current.SessionId
        windowsVersion = $os.Version
        windowsCaption = $os.Caption
    }

    $tpm = $null
    $getTpm = Get-Command Get-Tpm -ErrorAction SilentlyContinue
    if ($getTpm) {
        $deadline = (Get-Date).AddSeconds(50)
        do {
            $tpm = Get-Tpm -ErrorAction SilentlyContinue
            if ($tpm -and $tpm.TpmReady) { break }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
    }
    $cardTool = Join-Path ([Environment]::SystemDirectory) 'tpmvscmgr.exe'
    $cardToolPresent = Test-Path -LiteralPath $cardTool
    $secureBoot = $null
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch {}
    & $report 'RWLAB_TPM' @{
        getTpmAvailable = $null -ne $getTpm
        tpmPresent = $tpm -and $tpm.TpmPresent
        tpmReady = $tpm -and $tpm.TpmReady
        tpmManufacturer = if ($tpm) { $tpm.ManufacturerIdTxt } else { $null }
        secureBoot = $secureBoot
        virtualCardTool = $cardToolPresent
    }

    $attemptCard = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'create.virtual.card')
    if ($attemptCard) {
        $activeAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
        if ($activeAdapters.Count -ne 0 -or -not ($tpm -and $tpm.TpmReady) -or -not $cardToolPresent) {
            & $report 'RWLAB_CARD' @{ attempted = $false; readerVisible = $false; removed = $false }
        }
        else {
            # The documented default PIN is only used for this empty, disposable card.
            # No certificate, private-key enrollment or network logon occurs in this probe.
            $created = Invoke-LabCardCommand $cardTool 'create /name RWLAB-TemporaryCard /adminkey RANDOM /pin DEFAULT /generate'
            $instance = [regex]::Match($created.output, 'ROOT\\SMARTCARDREADER\\[0-9A-F]+', 'IgnoreCase')
            $visible = $false
            $removed = $false
            if ($instance.Success) {
                try {
                    $deadline = (Get-Date).AddSeconds(10)
                    do {
                        $visible = $null -ne (Get-PnpDevice -InstanceId $instance.Value -PresentOnly -ErrorAction SilentlyContinue)
                        if ($visible) { break }
                        Start-Sleep -Milliseconds 500
                    } while ((Get-Date) -lt $deadline)
                }
                finally {
                    $deleted = Invoke-LabCardCommand $cardTool ('destroy /instance ' + $instance.Value)
                    $removed = $deleted.exitCode -eq 0
                }
            }
            & $report 'RWLAB_CARD' @{
                attempted = $true
                readerVisible = $visible
                createExitCode = $created.exitCode
                removed = $removed
            }
        }
    }

    $additional = Join-Path $PSScriptRoot 'Run-RemoteWorkspaceFixture.ps1'
    if (Test-Path -LiteralPath $additional) {
        & $additional -MediaRoot $PSScriptRoot -Report $report *> $null
    }
    & $report 'RWLAB_COMPLETE' @{ virtualCardRequested = $attemptCard }
}
catch {
    & $report 'RWLAB_ERROR' @{ category = $_.CategoryInfo.Category.ToString() }
    throw 'The disposable guest probe failed.'
}
finally {
    $serial.Dispose()
}
