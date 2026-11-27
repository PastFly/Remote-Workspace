#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DisposableLab,
    [Parameter(Mandatory)][string]$BaselineMsi,
    [Parameter(Mandatory)][version]$BaselineVersion,
    [Parameter(Mandatory)][string]$TargetMsi,
    [Parameter(Mandatory)][string]$TargetSignature,
    [Parameter(Mandatory)][version]$TargetVersion,
    [string]$BaselineSha256,
    [string]$TargetSha256,
    [switch]$VerifyRestart
)

$ErrorActionPreference = 'Stop'
if (!$DisposableLab -or $env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) {
    Write-Output 'PREVIEW_INSTALL=SKIP disposable x64 Windows runner required'
    exit 77
}
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output 'PREVIEW_INSTALL=SKIP elevated runner required for unattended installation'
    exit 77
}

$repo = 'https://github.com/pastfly/remote-workspace'
$app = Join-Path $env:ProgramFiles 'Remote Workspace\RemoteWorkspace.exe'
$settings = 'HKCU:\Software\Remote Workspace'
$profile = Join-Path $env:LOCALAPPDATA 'Remote Workspace'
$cache = Join-Path $profile 'updates'
$result = Join-Path $cache 'last-result.txt'
$lab = Join-Path $env:TEMP ('remote-workspace-worker-qa-' + [guid]::NewGuid().ToString('N'))
$msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'

function Get-InstalledVersion {
    $file = [Diagnostics.FileVersionInfo]::GetVersionInfo($app)
    [version]::new($file.FileMajorPart, $file.FileMinorPart, $file.FileBuildPart)
}

function Require-Product([version]$expected) {
    if (!(Test-Path -LiteralPath $app -PathType Leaf) -or (Get-InstalledVersion) -ne $expected) {
        throw "Installed executable version did not match $expected."
    }
    $entries = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'Remote Workspace' })
    if ($entries.Count -ne 1 -or [version]$entries[0].DisplayVersion -ne $expected) {
        throw "Windows Installer registration did not match $expected."
    }
}

function Set-Channel([string]$channel, [bool]$automatic) {
    $mode = if ($automatic) { '1' } else { '0' }
    Set-ItemProperty -LiteralPath $settings -Name 'UpdateSettings' -Value "$mode`n$repo`n`n$channel"
}

function Invoke-Worker([byte[]]$signature, [int]$parentId, [long]$parentTicks, [bool]$restart, [scriptblock]$WhileRunning) {
    $id = [guid]::NewGuid().ToString('N')
    $stagedPackage = Join-Path $cache "$id.msi"
    $worker = Join-Path $cache "$id.exe"
    if (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result }
    Copy-Item -LiteralPath $TargetMsi -Destination $stagedPackage
    Copy-Item -LiteralPath $app -Destination $worker
    $restartArgument = if ($restart) { '1' } else { '0' }
    $arguments = @('--apply-update', $id, "$parentId", "$parentTicks", "$TargetVersion", $targetHash,
        '-', $restartArgument, $repo, [Convert]::ToBase64String($signature), 'preview')
    $process = Start-Process -FilePath $worker -ArgumentList $arguments -WorkingDirectory $cache -PassThru
    if ($WhileRunning) { & $WhileRunning $process }
    if (!$process.WaitForExit(120000)) { throw 'Update worker did not finish within two minutes.' }
    if (!(Test-Path -LiteralPath $result -PathType Leaf)) { throw "No result from the worker (exit $($process.ExitCode))." }
    if (Test-Path -LiteralPath $stagedPackage) { throw 'Completed worker left its staged MSI behind.' }
    $status = (Get-Content -LiteralPath $result -Encoding UTF8 -Raw).Trim()
    Write-Host "Worker exit $($process.ExitCode) / $status"
    Remove-Item -LiteralPath $worker
    $process.ExitCode
}

try {
    if ($BaselineVersion.Build -lt 0 -or $TargetVersion.Build -lt 0 -or
        $BaselineVersion.Revision -ge 0 -or $TargetVersion.Revision -ge 0 -or $TargetVersion -le $BaselineVersion) {
        throw 'Expected a newer three-component target version.'
    }
    if ((Test-Path -LiteralPath $app) -or (Test-Path -LiteralPath $settings) -or (Test-Path -LiteralPath $profile)) {
        throw 'Start from a clean Windows image with no Remote Workspace installation or profile.'
    }
    $BaselineMsi = (Resolve-Path -LiteralPath $BaselineMsi).Path
    $TargetMsi = (Resolve-Path -LiteralPath $TargetMsi).Path
    $TargetSignature = (Resolve-Path -LiteralPath $TargetSignature).Path
    $baseHash = (Get-FileHash -LiteralPath $BaselineMsi -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $TargetMsi -Algorithm SHA256).Hash
    if (($BaselineSha256 -and $baseHash -ne $BaselineSha256) -or ($TargetSha256 -and $targetHash -ne $TargetSha256)) {
        throw 'Input MSI SHA-256 differs from the expected published hash.'
    }
    [byte[]]$signature = [IO.File]::ReadAllBytes($TargetSignature)
    if ($signature.Length -ne 384) { throw 'The target must have its official detached RSA-3072 signature.' }
    $null = New-Item -ItemType Directory -Path $lab, $cache
    $null = New-Item -Path $settings
    $installLog = Join-Path $lab 'baseline-msi.log'
    $installer = Start-Process -FilePath $msiexec -ArgumentList @('/i', ('"'+$BaselineMsi+'"'), '/qn', '/norestart',
        '/l*v', ('"'+$installLog+'"')) -Wait -PassThru
    if ($installer.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installLog) { Get-Content -LiteralPath $installLog -Tail 35 | Write-Host }
        throw "Baseline MSI failed with exit $($installer.ExitCode)."
    }
    Require-Product $BaselineVersion
    Write-Host "PASS clean Windows Installer registration for $BaselineVersion"

    # Supply a real process identity for the already-closed parent path. This
    # avoids starting a WPF window on runners without an interactive desktop.
    $finishedParent = Start-Process -FilePath $env:ComSpec -ArgumentList '/d /c exit' -PassThru
    $finishedParent.WaitForExit()
    $closedPid = $finishedParent.Id
    # The PID already exited. A reused PID with another start time is also stale.
    $closedStart = 1L

    Set-Channel 'stable' $true
    if ((Invoke-Worker $signature $closedPid $closedStart $false) -ne 1) { throw 'Stable channel accepted a Preview package.' }
    Require-Product $BaselineVersion
    Write-Host 'PASS stable channel did not install the Preview'

    Set-Channel 'preview' $true
    [byte[]]$badSignature = $signature.Clone()
    $badSignature[0] = $badSignature[0] -bxor 1
    if ((Invoke-Worker $badSignature $closedPid $closedStart $false) -ne 1) { throw 'Invalid signature was accepted.' }
    Require-Product $BaselineVersion
    Write-Host 'PASS real Windows trust rejects a changed Preview signature'

    if ($VerifyRestart) {
        if (![Environment]::UserInteractive) { throw 'Restart smoke needs a visible Windows desktop.' }
        Set-Channel 'preview' $false
        $old = Start-Process -FilePath $app -PassThru
        if (!$old.WaitForInputIdle(10000)) { throw 'Baseline application never became interactive.' }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ($old.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 120
            $old.Refresh()
        }
        if ($old.HasExited -or $old.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Baseline main window unavailable.' }
        $onWorkerStart = {
            param($workerProcess)
            Start-Sleep -Seconds 1
            if ($workerProcess.HasExited) { throw 'Worker failed while waiting for its live installed parent.' }
            Require-Product $BaselineVersion
            if (!$old.CloseMainWindow() -or !$old.WaitForExit(15000)) { throw 'Baseline app did not close normally.' }
            Write-Host 'PASS real worker waited for the installed process before replacing files'
        }
        $code = Invoke-Worker $signature $old.Id $old.StartTime.ToUniversalTime().Ticks $true $onWorkerStart
    } else {
        $code = Invoke-Worker $signature $closedPid $closedStart $false
    }
    if ($code -ne 0) { throw "Preview worker failed (exit $code)." }
    Require-Product $TargetVersion
    Write-Host "PASS real msiexec applied Preview $TargetVersion"
    if ($VerifyRestart) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $new = @(Get-Process -Name RemoteWorkspace -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -ieq $app -and $_.MainWindowHandle -ne [IntPtr]::Zero })
            if ($new.Count -eq 1) { break }
            Start-Sleep -Milliseconds 180
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($new.Count -ne 1 -or $new[0].Id -eq $old.Id) { throw 'Installed target did not show a new main window.' }
        Write-Host 'PASS explicit update restarted the installed target executable'
        if (!$new[0].CloseMainWindow()) { throw 'Target window could not close normally.' }
    }
    Write-Output 'PREVIEW_INSTALL=PASS'
} catch {
    Write-Output ('PREVIEW_INSTALL=FAIL ' + $_.Exception.Message)
    exit 1
}
