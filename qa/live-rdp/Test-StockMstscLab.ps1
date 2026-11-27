#requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or
    $env:RW_LAB_ENDPOINT -notmatch '^127\.0\.0\.1:[0-9]+$' -or $env:RW_LAB_GUEST_USER -ne 'rdplab' -or
    [string]::IsNullOrWhiteSpace($env:RW_LAB_GUEST_PASSWORD) -or
    -not (Test-Path -LiteralPath $env:RW_LAB_GUEST_SERIAL)) {
    throw 'Start this smoke test through the disposable loopback RDP lab.'
}

Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
Add-Type -AssemblyName System.Drawing.Common
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RwStockMstscTest {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect result);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@

$rdpFile = Join-Path (Split-Path -Path $env:RW_LAB_GUEST_SERIAL -Parent) 'reference-mstsc.rdp'
$client = $null
$desktopWidth = 720
$desktopHeight = 520
$size = "$($desktopWidth)x$($desktopHeight)"

try {
    # Stock MSTSC reads this CurrentUser DPAPI credential for the disposable account.
    $secret = [Text.Encoding]::Unicode.GetBytes($env:RW_LAB_GUEST_PASSWORD)
    try {
        $credential = [Security.Cryptography.ProtectedData]::Protect(
            $secret, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $credentialHex = [Convert]::ToHexString($credential)
    }
    finally {
        [Array]::Clear($secret)
    }
    @(
        "full address:s:$($env:RW_LAB_ENDPOINT)"
        "username:s:$($env:RW_LAB_GUEST_USER)"
        "password 51:b:$credentialHex"
        'screen mode id:i:1'
        "desktopwidth:i:$desktopWidth"
        "desktopheight:i:$desktopHeight"
        'winposstr:s:0,1,50,48,795,625'
        'authentication level:i:1'
        'enablecredsspsupport:i:1'
        'prompt for credentials:i:0'
        'redirectsmartcards:i:0'
        'redirectclipboard:i:0'
    ) | Set-Content -LiteralPath $rdpFile -Encoding Unicode
    $credentialHex = $null

    $mstsc = Join-Path ([Environment]::SystemDirectory) 'mstsc.exe'
    $client = Start-Process -FilePath $mstsc -ArgumentList ('"' + $rdpFile + '"') -PassThru
    $deadline = (Get-Date).AddSeconds(65)
    while ((Get-Date) -lt $deadline -and -not $client.HasExited) {
        if (Select-String -LiteralPath $env:RW_LAB_GUEST_SERIAL -Pattern "^RDP_LAB_DISPLAY=$size\s*$" -Quiet) {
            break
        }
        Start-Sleep -Seconds 1
    }
    $sizes = @(
        Select-String -LiteralPath $env:RW_LAB_GUEST_SERIAL -Pattern '^RDP_LAB_DISPLAY=(\d+x\d+)\s*$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
    )
    if ($sizes -notcontains $size) {
        throw "Stock MSTSC did not start an authenticated guest desktop at the requested size. Guest sizes: $($sizes -join ', ')."
    }
    Write-Host "PASS stock MSTSC logged into the lab guest at $size."

    $expected = @(
        [Drawing.Color]::FromArgb(213, 46, 41)
        [Drawing.Color]::FromArgb(45, 181, 107)
        [Drawing.Color]::FromArgb(41, 91, 237)
        [Drawing.Color]::FromArgb(236, 197, 49)
    )
    $offsetX = 140, 550, 140, 550
    $offsetY = 145, 145, 410, 410
    $frame = [Drawing.Bitmap]::new(1, 1)
    try {
        $graphics = [Drawing.Graphics]::FromImage($frame)
        try {
            $deadline = (Get-Date).AddSeconds(12)
            do {
                $client.Refresh()
                $window = $client.MainWindowHandle
                $bounds = [RwStockMstscTest+Rect]::new()
                if ($window -ne [IntPtr]::Zero -and [RwStockMstscTest]::GetWindowRect($window, [ref] $bounds)) {
                    $null = [RwStockMstscTest]::SetForegroundWindow($window)
                    $matched = 0
                    for ($i = 0; $i -lt $expected.Length; $i++) {
                        $graphics.CopyFromScreen($bounds.Left + $offsetX[$i], $bounds.Top + $offsetY[$i], 0, 0, $frame.Size)
                        $pixel = $frame.GetPixel(0, 0)
                        $want = $expected[$i]
                        if ([Math]::Abs($pixel.R - $want.R) -le 30 -and
                            [Math]::Abs($pixel.G - $want.G) -le 30 -and
                            [Math]::Abs($pixel.B - $want.B) -le 30) {
                            $matched++
                        }
                    }
                    if ($matched -eq $expected.Length) {
                        Write-Host 'PASS stock MSTSC displayed all four authenticated RDP fixture quadrants.'
                        return
                    }
                }
                Start-Sleep -Milliseconds 500
            } while ((Get-Date) -lt $deadline)
            throw 'Stock MSTSC connected, but the expected guest pixels were not detected on the runner screen.'
        }
        finally {
            $graphics.Dispose()
        }
    }
    finally {
        $frame.Dispose()
    }
}
finally {
    if ($client) {
        if (-not $client.HasExited) {
            $client.Kill()
            $null = $client.WaitForExit(3000)
        }
        $client.Dispose()
    }
    Remove-Item -LiteralPath $rdpFile -Force -ErrorAction SilentlyContinue
}
