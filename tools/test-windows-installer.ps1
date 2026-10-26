param(
    [Parameter(Mandatory)]
    [string] $Installer
)

$ErrorActionPreference = 'Stop'
# This test installs and uninstalls the package. Only run on disposable CI runners.
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Installer integration checks must run on a Windows GitHub Actions runner'
}

$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$installDir = Join-Path $env:ProgramFiles 'gigachad'
$executable = Join-Path $installDir 'gigachad.exe'
$uninstaller = Join-Path $installDir 'unins000.exe'
if (Test-Path -LiteralPath $installDir) {
    throw "Refusing to replace an existing installation: $installDir"
}

$environmentKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
$rawValue = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
$originalPath = $environmentKey.GetValue('Path', $null, $rawValue)
$originalKind = if ($null -ne $originalPath) { $environmentKey.GetValueKind('Path') }
$baseline = "$originalPath;%USERPROFILE%\gigachad-path-check;"

function Invoke-Setup([string] $FilePath) {
    # -Wait includes child processes used by Inno Setup's bootstrap/uninstaller.
    $process = Start-Process -FilePath $FilePath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "Installer failed with exit code $($process.ExitCode): $FilePath"
    }
}

function Assert-UserPath([string] $Expected) {
    $actual = $environmentKey.GetValue('Path', $null, $rawValue)
    if ($actual -cne $Expected) {
        throw "Unexpected user PATH. Expected '$Expected', got '$actual'"
    }
}

try {
    $environmentKey.SetValue('Path', $baseline, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Invoke-Setup $installerPath
    if (-not (Test-Path -LiteralPath $executable)) {
        throw "Installed executable is missing: $executable"
    }
    if ((Get-FileHash -LiteralPath $executable).Hash -ne (Get-FileHash -LiteralPath 'zig-out/bin/gigachad.exe').Hash) {
        throw 'Installed executable differs from the build output'
    }
    & $executable --version
    if ($LASTEXITCODE -ne 0) { throw 'Installed executable failed to run' }
    Assert-UserPath "$baseline;$installDir"

    # Reinstallation must neither duplicate PATH nor lose ownership of the entry.
    Invoke-Setup $installerPath
    Assert-UserPath "$baseline;$installDir"
    # Preserve entries added by the user after installation as well.
    $laterEntry = ';%USERPROFILE%\gigachad-added-later'
    $environmentKey.SetValue('Path', "$baseline;$installDir$laterEntry", [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Invoke-Setup $uninstaller
    Assert-UserPath "$baseline$laterEntry"
    if (Test-Path -LiteralPath $executable) { throw 'Uninstall did not remove the executable' }

    # Respect an entry that existed before setup, including case/quotes/slashes.
    $existingPath = "$baseline;`"$($installDir.ToUpperInvariant())\`""
    $environmentKey.SetValue('Path', $existingPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Invoke-Setup $installerPath
    Assert-UserPath $existingPath
    Invoke-Setup $uninstaller
    Assert-UserPath $existingPath

    # A user without a PATH value must also be able to install and uninstall.
    $environmentKey.DeleteValue('Path', $false)
    Invoke-Setup $installerPath
    Assert-UserPath $installDir
    Invoke-Setup $uninstaller
    Assert-UserPath ''
    Write-Host 'Windows installation, reinstallation, user PATH and uninstall checks passed.'
}
finally {
    try {
        if (Test-Path -LiteralPath $uninstaller) { Invoke-Setup $uninstaller }
    }
    finally {
        if ($null -eq $originalPath) {
            $environmentKey.DeleteValue('Path', $false)
        }
        else {
            $environmentKey.SetValue('Path', $originalPath, $originalKind)
        }
        $environmentKey.Dispose()
    }
}
