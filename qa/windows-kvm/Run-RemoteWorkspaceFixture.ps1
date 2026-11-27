#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MediaRoot,
    [Parameter(Mandatory)][scriptblock] $Report
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'The resize test must run on the disposable Windows guest desktop.'
}

$msiName = 'Remote-Workspace-0.8.4-x64.msi'
$msi = Join-Path $MediaRoot $msiName
$baselineHash = '9DCDD34168EF211CDCD09FE0BBD1407EA3CE1B226B7FE0C6C0F3525898051FD8'
if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ne $baselineHash) {
    throw 'Published 0.8.4 MSI does not match the pinned digest.'
}
$probe = Join-Path $MediaRoot 'LiveMstscFitSmoke.exe'
$rootCert = Join-Path $MediaRoot 'rdp-lab-root.cer'
$protectedPassword = $null
$client = $null
$certificate = $null
$measurements = @{}
$rdpFile = Join-Path ([IO.Path]::GetTempPath()) ('rw-lab-' + [Guid]::NewGuid().ToString('N') + '.rdp')
$phase = 'install-published-baseline'
try {
    $msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    $install = Start-Process -FilePath $msiexec -ArgumentList @('/i', ('"' + $msi + '"'), '/qn', '/norestart') -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "Published 0.8.4 MSI exited $($install.ExitCode)." }
    $app = Join-Path $env:ProgramFiles 'Remote Workspace\RemoteWorkspace.exe'
    $version = (Get-Item -LiteralPath $app).VersionInfo.FileVersion
    if ($version -ne '0.8.4.0') { throw "Unexpected installed version $version." }

    $phase = 'authenticate-disposable-rdp-guest'
    $certificate = Import-Certificate -FilePath $rootCert -CertStoreLocation 'Cert:\LocalMachine\Root'
    Add-Type -AssemblyName System.Security
    $secretPath = Join-Path $MediaRoot 'rdp-password.txt'
    $secret = [Text.Encoding]::Unicode.GetBytes([IO.File]::ReadAllText($secretPath))
    try {
        $protectedPassword = [Security.Cryptography.ProtectedData]::Protect(
            $secret, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    }
    finally { [Array]::Clear($secret, 0, $secret.Length) }
    $hex = [BitConverter]::ToString($protectedPassword).Replace('-', '')
    @(
        'full address:s:10.0.2.100:3389'
        'username:s:rdplab'
        "password 51:b:$hex"
        'screen mode id:i:1'
        'desktopwidth:i:1067'
        'desktopheight:i:662'
        'session bpp:i:32'
        'allow font smoothing:i:1'
        'use multimon:i:0'
        'displayconnectionbar:i:0'
        'dynamic resolution:i:0'
        'smart sizing:i:1'
        'winposstr:s:0,1,0,0,1067,662'
        'authentication level:i:1'
        'enablecredsspsupport:i:1'
        'prompt for credentials:i:0'
        'redirectsmartcards:i:0'
        'redirectclipboard:i:0'
    ) | Set-Content -LiteralPath $rdpFile -Encoding Unicode
    $hex = $null
    [Array]::Clear($protectedPassword, 0, $protectedPassword.Length)
    $mstsc = Join-Path ([Environment]::SystemDirectory) 'mstsc.exe'
    $client = Start-Process -FilePath $mstsc -ArgumentList ('"' + $rdpFile + '"') -PassThru

    $phase = 'measure-published-host-with-stock-mstsc'
    & $probe $app --expect-084-limited --attach $client.Id 2>&1 | ForEach-Object {
        $line = [string] $_
        if ($line -match '^(Initial|Growth|Shrink): viewport=\{Width=(\d+), Height=(\d+)\}; stage=\{Width=(\d+), Height=(\d+)\}; measured-marker=\{X=(-?\d+),Y=(-?\d+),Width=(\d+),Height=(\d+)\}') {
            $measurements[$Matches[1]] = @{
                viewport = @([int] $Matches[2], [int] $Matches[3])
                stage = @([int] $Matches[4], [int] $Matches[5])
                frame = @([int] $Matches[6], [int] $Matches[7], [int] $Matches[8], [int] $Matches[9])
            }
        }
    }
    $probeExit = $LASTEXITCODE
    $result = @{
        passed = $probeExit -eq 0 -and $measurements.Count -eq 3
        version = $version
        scope = 'published-0.8.4-with-stock-mstsc'
        measurements = $measurements
        candidateTested = $false
        smartCardTested = $false
    }
    if ($result.passed) { $result.growth = 'native-100-percent' }
    & $Report 'RWLAB_FIT_RESULT' $result
    if ($probeExit -ne 0) { throw 'The resize pixel oracle did not pass.' }
    if (-not $result.passed) { throw 'The pixel oracle did not emit the three expected measurements.' }
}
catch {
    & $Report 'RWLAB_FIT_RESULT' @{ passed = $false; version = '0.8.4.0'; measurements = $measurements; phase = $phase }
    throw
}
finally {
    if ($client) {
        if (-not $client.HasExited) { $client.Kill(); $null = $client.WaitForExit(3000) }
        $client.Dispose()
    }
    Remove-Item -LiteralPath $rdpFile -Force -ErrorAction SilentlyContinue
    if ($certificate) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)" -Force }
}
