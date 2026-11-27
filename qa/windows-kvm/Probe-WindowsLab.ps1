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
            $null = $command.WaitForExit(3000)
            return -1
        }
        $null = $output.GetAwaiter().GetResult()
        $null = $errorOutput.GetAwaiter().GetResult()
        return $command.ExitCode
    }
    finally {
        $command.Dispose()
    }
}

function Get-LabReaderState {
    $readerIds = @(
        Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object Class -eq 'SmartCardReader' |
            Select-Object -ExpandProperty InstanceId
    )
    [string[]] $pcscReaders = $null
    $pcscHResult = $null
    try { $pcscHResult = '0x{0:X8}' -f ([RwLabPcsc]::ListReaders([ref] $pcscReaders)) } catch {}
    $service = Get-Service -Name SCardSvr -ErrorAction SilentlyContinue
    return [pscustomobject] @{
        readerIds = $readerIds
        pcscReaders = $pcscReaders
        pcscHResult = $pcscHResult
        serviceStatus = if ($service) { [string] $service.Status } else { 'Missing' }
    }
}

function Request-LabSmartCardService {
    $service = Get-Service -Name SCardSvr -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Stopped') {
        try { $service.Start() } catch {}
    }
}

function Test-LabVirtualReader([string] $CardTool) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RwLabPcsc
{
    private const uint SystemScope = 2;
    private const int NoReaders = unchecked((int)0x8010002E);

    [DllImport("winscard.dll", ExactSpelling = true)]
    private static extern int SCardEstablishContext(uint scope, IntPtr reserved1,
                                                      IntPtr reserved2, out IntPtr context);

    [DllImport("winscard.dll", ExactSpelling = true)]
    private static extern int SCardReleaseContext(IntPtr context);

    [DllImport("winscard.dll", ExactSpelling = true)]
    private static extern int SCardListReadersW(IntPtr context, IntPtr groups,
                                                IntPtr readers, ref uint characters);

    public static int ListReaders(out string[] readers)
    {
        readers = null;
        IntPtr context;
        int status = SCardEstablishContext(SystemScope, IntPtr.Zero, IntPtr.Zero, out context);
        if (status != 0) return status;
        try
        {
            uint characters = 0;
            status = SCardListReadersW(context, IntPtr.Zero, IntPtr.Zero, ref characters);
            if (status == NoReaders || (status == 0 && characters == 0)) readers = new string[0];
            if (status != 0 || characters == 0) return status;

            IntPtr buffer = Marshal.AllocHGlobal(checked((int)characters * sizeof(char)));
            try
            {
                status = SCardListReadersW(context, IntPtr.Zero, buffer, ref characters);
                if (status == NoReaders || (status == 0 && characters == 0))
                    readers = new string[0];
                else if (status == 0)
                    readers = Marshal.PtrToStringUni(buffer, checked((int)characters))
                        .Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
                return status;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { SCardReleaseContext(context); }
    }
}
'@

    $noService = '0x8010001D'
    Request-LabSmartCardService
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $before = Get-LabReaderState
        if ($null -ne $before.pcscReaders -or $before.pcscHResult -ne $noService) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    $baselineUnknown = $before.pcscHResult -eq $noService -and $before.readerIds.Count -eq 0
    if ($null -eq $before.pcscReaders -and -not $baselineUnknown) {
        return @{
            attempted = $false
            createdState = 'pcsc-baseline-error'
            readerVisible = $false
            removed = $false
            pcscBaselineUnknown = $false
            pcscBeforeHResult = $before.pcscHResult
            serviceStatusBefore = $before.serviceStatus
            pnpCountBefore = $before.readerIds.Count
        }
    }

    # The documented default PIN is used only for this empty, disposable card.
    $creationExitCode = Invoke-LabCardCommand $CardTool 'create /name RWLAB-TemporaryCard /adminkey RANDOM /pin DEFAULT /generate'
    $visible = $false
    $removed = $false
    $destroyExitCode = $null
    $afterRemoval = $null
    $serviceRequestedAfterCreate = $false
    $baselineCountForComparison = if ($baselineUnknown) { 0 } else { $before.pcscReaders.Count }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $afterCreation = Get-LabReaderState
        $newIds = @($afterCreation.readerIds | Where-Object { $before.readerIds -notcontains $_ })
        $newPcsc = @($afterCreation.pcscReaders | Where-Object { $null -ne $_ -and $before.pcscReaders -notcontains $_ })
        if ($newIds.Count -eq 1 -and $newPcsc.Count -eq 1 -and
            $afterCreation.pcscReaders.Count -eq ($baselineCountForComparison + 1)) { break }
        if ($newIds.Count -eq 1 -and $afterCreation.pcscHResult -eq $noService -and -not $serviceRequestedAfterCreate) {
            Request-LabSmartCardService
            $serviceRequestedAfterCreate = $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    $verifiedId = $null
    if ($newIds.Count -eq 1 -and $newIds[0] -match '^ROOT\\SMARTCARDREADER\\[A-F0-9]{4}$') {
        $verifiedId = $newIds[0]
    }
    $visible = $creationExitCode -eq 0 -and $null -ne $verifiedId -and $newPcsc.Count -eq 1 -and
        $afterCreation.pcscReaders.Count -eq ($baselineCountForComparison + 1)

    # Use only the new exact PnP instance, never a device ID parsed from command output.
    if ($null -ne $verifiedId) {
        $destroyExitCode = Invoke-LabCardCommand $CardTool ('destroy /instance ' + $verifiedId)
        $deadline = (Get-Date).AddSeconds(20)
        do {
            $afterRemoval = Get-LabReaderState
            $matchingReaders = $null -ne $afterRemoval.pcscReaders -and
                $afterRemoval.pcscReaders.Count -eq $baselineCountForComparison -and
                @($afterRemoval.pcscReaders | Where-Object { $before.pcscReaders -notcontains $_ }).Count -eq 0
            $sameNoService = $baselineUnknown -and $afterRemoval.pcscHResult -eq $noService
            $matchingReaders = $matchingReaders -or $sameNoService
            $removed = $destroyExitCode -eq 0 -and $matchingReaders -and $afterRemoval.readerIds -notcontains $verifiedId
            if ($removed) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
    }

    $createdState = if ($visible) { 'observed' }
        elseif ($creationExitCode -ne 0) { 'create-failed' }
        elseif ($null -eq $verifiedId) { 'new-pnp-instance-unverified' }
        else { 'new-pcsc-reader-unverified' }
    return @{
        attempted = $true
        createdState = $createdState
        readerVisible = $visible
        createExitCode = $creationExitCode
        destroyExitCode = $destroyExitCode
        removed = $removed
        newPnpCount = $newIds.Count
        pnpCountBefore = $before.readerIds.Count
        pcscBaselineUnknown = $baselineUnknown
        pcscCountBefore = if ($null -ne $before.pcscReaders) { $before.pcscReaders.Count } else { $null }
        pcscCountAfterCreate = if ($null -ne $afterCreation.pcscReaders) { $afterCreation.pcscReaders.Count } else { $null }
        pcscCountAfterDestroy = if ($null -ne $afterRemoval -and $null -ne $afterRemoval.pcscReaders) { $afterRemoval.pcscReaders.Count } else { $null }
        pcscBeforeHResult = $before.pcscHResult
        pcscAfterCreateHResult = $afterCreation.pcscHResult
        pcscAfterDestroyHResult = if ($null -ne $afterRemoval) { $afterRemoval.pcscHResult } else { $null }
        serviceStatusBefore = $before.serviceStatus
        serviceStatusAfterCreate = $afterCreation.serviceStatus
        serviceStatusAfterDestroy = if ($null -ne $afterRemoval) { $afterRemoval.serviceStatus } else { $null }
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
            & $report 'RWLAB_CARD' @{ attempted = $false; createdState = 'precondition-unmet'; readerVisible = $false; removed = $false }
        }
        else {
            & $report 'RWLAB_CARD' (Test-LabVirtualReader $cardTool)
        }
    }

    $additional = Join-Path $PSScriptRoot 'Run-RemoteWorkspaceFixture.ps1'
    $fitRequested = Test-Path -LiteralPath $additional
    if ($fitRequested) {
        & $additional -MediaRoot $PSScriptRoot -Report $report *> $null
    }
    & $report 'RWLAB_COMPLETE' @{ virtualCardRequested = $attemptCard; fitRequested = $fitRequested }
}
catch {
    & $report 'RWLAB_ERROR' @{ category = $_.CategoryInfo.Category.ToString() }
    throw 'The disposable guest probe failed.'
}
finally {
    $serial.Dispose()
}
