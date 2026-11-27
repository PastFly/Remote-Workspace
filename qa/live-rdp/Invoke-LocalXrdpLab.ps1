#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $TestScript,
    [ValidateRange(1024, 65535)]
    [int] $Port = 33890,
    [ValidateRange(60, 1200)]
    [int] $ReadySeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This script is scoped to an ephemeral GitHub-hosted Windows runner.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'The runner temporary directory is not set.' }
$testPath = if ($TestScript) { (Resolve-Path -LiteralPath $TestScript).Path } else { $null }

function Invoke-LabNative([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Command)) failed with exit code $LASTEXITCODE." }
}

function Save-VerifiedLabFile([string] $Url, [string] $Path, [string] $Sha256) {
    Invoke-LabNative (Join-Path ([Environment]::SystemDirectory) 'curl.exe') @(
        '--fail', '--silent', '--show-error', '--proto', '=https', '--location',
        '--retry', '2', '--max-time', '300', '--output', $Path, $Url
    )
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Digest mismatch for $([IO.Path]::GetFileName($Path))."
    }
}

function Test-LabRdpTls([int] $LabPort) {
    $socket = [Net.Sockets.TcpClient]::new()
    try {
        $socket.ReceiveTimeout = 5000
        $socket.SendTimeout = 5000
        $socket.Connect([Net.IPAddress]::Loopback, $LabPort)
        $stream = $socket.GetStream()
        # TPKT and COTP connection request with PROTOCOL_SSL.
        [byte[]] $request = 3, 0, 0, 19, 14, 0xe0, 0, 0, 0, 0, 0, 1, 0, 8, 0, 1, 0, 0, 0
        [byte[]] $header = [byte[]]::new(4)
        $stream.Write($request, 0, $request.Length)
        $stream.ReadExactly($header, 0, $header.Length)
        if ($header[0] -ne 3 -or $header[2] -ne 0 -or $header[3] -ne 19) {
            throw 'The loopback guest did not return an RDP negotiation packet.'
        }
        [byte[]] $packet = [byte[]]::new(15)
        $stream.ReadExactly($packet, 0, $packet.Length)
        if ($packet[1] -ne 0xd0 -or $packet[7] -ne 2 -or [BitConverter]::ToUInt32($packet, 11) -ne 1) {
            throw 'The loopback guest did not select RDP over TLS.'
        }
        $tls = [Net.Security.SslStream]::new($stream, $true)
        try {
            $tls.AuthenticateAsClient('127.0.0.1')
            Write-Host "Loopback RDP negotiation and certificate validation passed ($($tls.SslProtocol))."
        }
        finally {
            $tls.Dispose()
        }
    }
    finally {
        $socket.Dispose()
    }
}

$lab = Join-Path $env:RUNNER_TEMP ("rw-xrdp-" + [Guid]::NewGuid().ToString('N'))
$vm = $null
$ca = $null

try {
    New-Item -Path $lab -ItemType Directory | Out-Null
    $msys = 'C:\msys64'
    $qemu = Join-Path $msys 'ucrt64/bin/qemu-system-x86_64.exe'
    if (-not (Test-Path -LiteralPath $qemu)) {
        Invoke-LabNative (Join-Path $msys 'usr/bin/bash.exe') @(
            '-lc', 'pacman --noconfirm -Sy --needed mingw-w64-ucrt-x86_64-qemu'
        )
    }
    Invoke-LabNative $qemu @('--version')

    $disk = Join-Path $lab 'guest.qcow2'
    $wheel = Join-Path $lab 'pycdlib-1.14.0-py2.py3-none-any.whl'
    $diskUrl = 'https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img'
    $wheelUrl = 'https://files.pythonhosted.org/packages/0c/dd/95557c0e3bad0e8ba10c0f17d9deffb139b106eda528a744e544799cbbfb/pycdlib-1.14.0-py2.py3-none-any.whl'
    Save-VerifiedLabFile $diskUrl $disk '04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94'
    Save-VerifiedLabFile $wheelUrl $wheel 'a905827335f0066af3fd416c5cf9b1f29dffaf4d0914b714555213d1809f38d4'

    $qemuImg = Join-Path $msys 'ucrt64/bin/qemu-img.exe'
    Invoke-LabNative $qemuImg @('resize', '-f', 'qcow2', $disk, '8G')

    $openssl = (Get-Command openssl.exe).Source
    $issuer = Join-Path $lab 'issuer.pem'
    $issuerDer = Join-Path $lab 'issuer.cer'
    $issuerKey = Join-Path $lab 'issuer.key'
    $serverRequest = Join-Path $lab 'server.csr'
    $serverKey = Join-Path $lab 'rdp-lab-server.key'
    $serverCert = Join-Path $lab 'rdp-lab-server.pem'
    $extensions = Join-Path $lab 'server.ext'
    @(
        'basicConstraints=critical,CA:FALSE'
        'keyUsage=critical,digitalSignature,keyEncipherment'
        'extendedKeyUsage=serverAuth'
        'subjectAltName=IP:127.0.0.1,DNS:localhost'
    ) | Set-Content -LiteralPath $extensions -Encoding ascii

    Invoke-LabNative $openssl @(
        'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
        '-subj', '/CN=Remote Workspace ephemeral RDP lab',
        '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
        '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        '-keyout', $issuerKey, '-out', $issuer
    )
    Invoke-LabNative $openssl @(
        'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1',
        '-keyout', $serverKey, '-out', $serverRequest
    )
    Invoke-LabNative $openssl @(
        'x509', '-req', '-in', $serverRequest, '-CA', $issuer, '-CAkey', $issuerKey,
        '-CAcreateserial', '-sha256', '-days', '1', '-extfile', $extensions, '-out', $serverCert
    )
    Invoke-LabNative $openssl @('x509', '-in', $issuer, '-outform', 'DER', '-out', $issuerDer)
    Remove-Item -LiteralPath $issuerKey -Force

    $env:RW_LAB_GUEST_PASSWORD = 'Xx!9-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(18))
    $env:REMOTE_WORKSPACE_TEST_RDP_PASSWORD = $env:RW_LAB_GUEST_PASSWORD
    $python = (Get-Command python.exe).Source
    Invoke-LabNative $python @((Join-Path $PSScriptRoot 'prepare-xrdp-guest.py'), $lab, $wheel)
    $ca = Import-Certificate -FilePath $issuerDer -CertStoreLocation 'Cert:\CurrentUser\Root'

    $serial = Join-Path $lab 'guest-serial.txt'
    $qemuError = Join-Path $lab 'qemu-error.txt'
    $vm = Start-Process -FilePath $qemu -WorkingDirectory $lab -PassThru -RedirectStandardError $qemuError -ArgumentList @(
        '-machine', 'q35,accel=tcg', '-smp', '2', '-m', '2048',
        '-display', 'none', '-monitor', 'none', '-no-reboot',
        '-serial', 'file:guest-serial.txt',
        '-drive', 'file=guest.qcow2,format=qcow2,if=virtio',
        '-drive', 'file=cidata.iso,format=raw,media=cdrom,readonly=on',
        '-device', 'virtio-net-pci,netdev=isolated',
        '-netdev', ('user,id=isolated,hostfwd=tcp:127.0.0.1:' + $Port + '-:3389')
    )

    $deadline = (Get-Date).AddSeconds($ReadySeconds)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $vm.HasExited) {
        if ((Test-Path -LiteralPath $serial) -and (Select-String -LiteralPath $serial -SimpleMatch 'RDP_LAB_READY' -Quiet)) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        $errors = @(Get-Content -LiteralPath $qemuError -Tail 12 -ErrorAction SilentlyContinue)
        $guestErrorPattern = 'Failed to start|Could not resolve|Temporary failure resolving|Failed to fetch|Failed to run module'
        $guestErrors = @(
            Select-String -LiteralPath $serial -Pattern $guestErrorPattern -ErrorAction SilentlyContinue |
                Select-Object -Last 12 |
                ForEach-Object Line
        )
        throw "The RDP guest did not start. $($errors -join ' ') $($guestErrors -join ' ')"
    }

    Test-LabRdpTls $Port
    $env:RW_LAB_ENDPOINT = "127.0.0.1:$Port"
    $env:RW_LAB_GUEST_USER = 'rdplab'
    $env:RW_LAB_GUEST_SERIAL = $serial
    Write-Host "RDP lab ready on $($env:RW_LAB_ENDPOINT)."
    if ($testPath) {
        & $testPath
        if (-not $?) { throw 'The live RDP test failed.' }
    }
}
finally {
    try {
        if ($vm) {
            if (-not $vm.HasExited) {
                $vm.Kill()
                $null = $vm.WaitForExit(5000)
            }
            $vm.Dispose()
        }
    }
    finally {
        $env:RW_LAB_GUEST_PASSWORD = $null
        $env:REMOTE_WORKSPACE_TEST_RDP_PASSWORD = $null
        $env:RW_LAB_ENDPOINT = $null
        $env:RW_LAB_GUEST_USER = $null
        $env:RW_LAB_GUEST_SERIAL = $null
        if ($ca) { Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$($ca.Thumbprint)" -Force }
        if (Test-Path -LiteralPath $lab) { Remove-Item -LiteralPath $lab -Recurse -Force }
    }
}
