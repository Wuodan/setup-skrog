<#
.SYNOPSIS
  Install a pinned Skrog release on Windows: download the zip for this
  architecture, verify it against the release's SHA256SUMS, put skrog.exe on
  PATH, and (optionally) install + start the engine and wait until it answers.

.DESCRIPTION
  One script, two callers: the setup-skrog GitHub Action, and GitLab or any
  other CI via before_script. Nothing is fetched as "latest" unless you ask for
  it: -Version pins the Skrog release, and a skrog.lock (auto-detected in the
  working directory, or -Lockfile) pins the engine it installs -- so a laptop
  and a runner converge on the same engine.

  Feature detection keeps it working with older releases: `--locked` and
  `skrog healthcheck` are used only when the installed skrog supports them.

  WSL2 is required to install the engine (GitHub-hosted windows-latest runners
  have it). On a machine without WSL2, run with -Install:$false to stage
  skrog.exe only.

.EXAMPLE
  pwsh -File install-skrog.ps1 -Version 0.3.0
.EXAMPLE
  pwsh -File install-skrog.ps1 -Install:$false          # stage skrog.exe only
#>
[CmdletBinding()]
param(
  [string]$Version = 'latest',
  [string]$Lockfile = '',
  [bool]$Install = $true,
  [string]$InstallArgs = '',
  [string]$Wait = '3m',
  [string]$Dest = '',
  [string]$Token = $env:GH_TOKEN
)
$ErrorActionPreference = 'Stop'
# pwsh 7.4+ turns a native command's non-zero exit into a terminating error under
# ErrorActionPreference=Stop. This script inspects exit codes itself (`skrog
# version` legitimately exits 3 with no engine; `wsl --status` fails where WSL2
# is absent), so keep native exit codes as data, not exceptions.
$PSNativeCommandUseErrorActionPreference = $false
$repo = 'Wuodan/skrog'
$downloadTimeoutSeconds = 120

# Out-CI appends a line to a GitHub Actions command file when running there;
# elsewhere (GitLab, a laptop) the variables are simply unset and nothing happens.
function Out-CI([string]$file, [string]$line) {
  if ($file) { Add-Content -Path $file -Value $line }
}

function Write-Phase([string]$message) {
  Write-Host ("[{0:O}] setup-skrog: {1}" -f (Get-Date), $message)
}

# --- 1. resolve the release --------------------------------------------------
$Version = $Version -replace '^v', ''
Write-Phase 'resolving Skrog release'
if (-not $Version -or $Version -eq 'latest') {
    # The skrog repo also publishes rootfs releases (tags rootfs-*), and
    # GitHub's /releases/latest can return one of those. "Latest" here means the
    # newest published app release: a v<semver> tag that is not a draft. Every
    # pre-1.0 release is flagged prerelease, so a stable one is preferred when it
    # exists but a prerelease is not excluded.
    $headers = @{ 'User-Agent' = 'setup-skrog' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $rels = Invoke-RestMethod -Headers $headers -TimeoutSec $downloadTimeoutSeconds "https://api.github.com/repos/$repo/releases?per_page=50"
    $apps = @($rels | Where-Object { $_.tag_name -match '^v\d+\.\d+\.\d+$' -and -not $_.draft } |
      Sort-Object { [version]($_.tag_name -replace '^v', '') } -Descending)
    $app = @($apps | Where-Object { -not $_.prerelease })[0]
    if (-not $app) { $app = $apps[0] }
    if (-not $app) { throw "no published skrog release found in $repo" }
    $Version = $app.tag_name -replace '^v', ''
}
Write-Phase "downloading Skrog $Version"

# --- 2. download and verify --------------------------------------------------
$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
$zip = "skrog_${Version}_windows_$arch.zip"
$base = "https://github.com/$repo/releases/download/v$Version"
if (-not $Dest) {
  $tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  $Dest = Join-Path $tmp "skrog-$Version"
}
New-Item -ItemType Directory -Force $Dest | Out-Null
$zipPath = Join-Path $Dest $zip
$sumsPath = Join-Path $Dest 'SHA256SUMS'
Invoke-WebRequest -TimeoutSec $downloadTimeoutSeconds "$base/$zip" -OutFile $zipPath
Write-Phase 'downloading Skrog checksum'
Invoke-WebRequest -TimeoutSec $downloadTimeoutSeconds "$base/SHA256SUMS" -OutFile $sumsPath

# SHA256SUMS is `<hash>  <file>` per line; the leading * of binary mode is allowed.
$entry = Get-Content $sumsPath | Where-Object { $_ -match "\s+\*?$([regex]::Escape($zip))\s*$" } | Select-Object -First 1
if (-not $entry) { throw "SHA256SUMS has no entry for $zip" }
$expected = ($entry -split '\s+')[0].ToLower()
$actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw "checksum mismatch for ${zip}: expected $expected, got $actual" }
Write-Phase "verified $zip (sha256 $actual)"

Write-Phase 'extracting Skrog'
$bin = Join-Path $Dest 'bin'
Expand-Archive $zipPath -DestinationPath $bin -Force
$skrog = Join-Path $bin 'skrog.exe'
if (-not (Test-Path $skrog)) { throw "skrog.exe not found after extracting $skrog" }

# --- 3. expose ---------------------------------------------------------------
$env:Path = "$bin;$env:Path"
Out-CI $env:GITHUB_PATH $bin
Out-CI $env:GITHUB_ENV "SKROG_HOME=$bin"
Out-CI $env:GITHUB_OUTPUT "version=$Version"
Out-CI $env:GITHUB_OUTPUT "home=$bin"
# `skrog version` exits 3 with no engine installed; that is expected here.
Write-Phase 'checking the Skrog binary'
& $skrog version 2>$null | Out-Host
if (-not $Install) {
  Write-Host "skrog $Version staged at $bin (engine install skipped)"
  exit 0
}

# --- 4. WSL2 gate ------------------------------------------------------------
Write-Phase 'checking WSL2'
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
  throw ("WSL2 is not available on this machine (`wsl --status` failed). Enable WSL2 on the runner " +
    "(wsl --install --no-distribution, then reboot), or run with -Install:`$false " +
    "(action input install: false) to stage skrog.exe only.")
}

# --- 5. install the engine (feature-detecting what this release supports) ----
Write-Phase 'reading Skrog install options'
$installHelp = (& $skrog install --help 2>&1 | Out-String)
# Not $args (an automatic variable this script also splats), and not
# $installArgs either: PowerShell variable names are case-insensitive, so that
# one IS the -InstallArgs parameter, and assigning to it fed the arguments back
# into themselves.
$cmdArgs = @('install', '--headless', '--no-autostart')
# A cancelled wsl.exe used to leave this process waiting indefinitely for an
# inherited output handle. Newer Skrog releases bound the whole install; keep
# this debugging action below its five-minute job timeout without changing the
# public action interface.
if ($installHelp -match '(?m)^\s*-timeout\s+') { $cmdArgs += @('--timeout', '4m') }
if (-not $Lockfile -and (Test-Path 'skrog.lock')) { $Lockfile = 'skrog.lock' }
if ($Lockfile) {
  if ($installHelp -match '--locked') { $cmdArgs += @('--locked', $Lockfile) }
  else { Write-Warning "skrog $Version does not support --locked; ignoring $Lockfile" }
}
if ($InstallArgs) { $cmdArgs += ($InstallArgs -split ' ' | Where-Object { $_ }) }
Write-Phase 'running skrog install'
& $skrog @cmdArgs
if ($LASTEXITCODE -ne 0) { throw "skrog install failed (exit $LASTEXITCODE)" }
Write-Phase 'running skrog start'
& $skrog start
if ($LASTEXITCODE -ne 0) { throw "skrog start failed (exit $LASTEXITCODE)" }

# --- 6. wait until docker commands will succeed -------------------------------
$topHelp = (& $skrog --help 2>&1 | Out-String)
if ($topHelp -match 'healthcheck') {
  Write-Phase "waiting for engine readiness ($Wait)"
  & $skrog healthcheck --wait $Wait
  if ($LASTEXITCODE -ne 0) { throw "engine not ready after $Wait" }
} else {
  Write-Phase "polling engine readiness ($Wait)"
  # Older release: poll status --json ourselves.
  $secs = switch -regex ($Wait) {
    '^(\d+)s$' { [int]$Matches[1] }
    '^(\d+)m$' { 60 * [int]$Matches[1] }
    '^(\d+)h$' { 3600 * [int]$Matches[1] }
    default    { 180 }
  }
  $deadline = (Get-Date).AddSeconds($secs)
  do {
    $st = (& $skrog status --json 2>$null | Out-String | ConvertFrom-Json)
    if ($st.supervisor -eq 'running' -and $st.engine -in @('running', 'idle')) { break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if (-not ($st.supervisor -eq 'running' -and $st.engine -in @('running', 'idle'))) { throw "engine not ready after $Wait" }
}

# docker follows the context Skrog wired at install; anything else in the job
# (compose, Testcontainers, Dev Containers) follows docker.
Out-CI $env:GITHUB_ENV 'DOCKER_CONTEXT=skrog'
Write-Host "engine ready; docker context 'skrog' targets it"
& $skrog status --json | Out-Host
