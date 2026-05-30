# QuickPatch installer for Windows (PowerShell).
#
#   irm https://raw.githubusercontent.com/letssuhail/quickpatch-cli/main/install/install.ps1 | iex
#
# Clones the QuickPatch CLI into %USERPROFILE%\.quickpatch (the install root IS
# the git checkout, so `quickpatch upgrade` can git-reset to latest), then builds
# the quickpatch.exe snapshot. Flutter + the patched iOS engine are fetched on
# first run by the CLI itself.

$ErrorActionPreference = 'Stop'

$RepoUrl = if ($env:QUICKPATCH_REPO_URL) { $env:QUICKPATCH_REPO_URL } else { 'https://github.com/letssuhail/quickpatch-cli.git' }
$Branch  = if ($env:QUICKPATCH_BRANCH)   { $env:QUICKPATCH_BRANCH }   else { 'main' }
$Root    = if ($env:QUICKPATCH_ROOT)     { $env:QUICKPATCH_ROOT }     else { Join-Path $env:USERPROFILE '.quickpatch' }
$BinDir  = Join-Path $Root 'bin'

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git is required but was not found on PATH.'
}

if (Test-Path (Join-Path $Root '.git')) {
  Info "Updating existing QuickPatch checkout at $Root..."
  git -C $Root fetch --depth 1 origin $Branch
  git -C $Root reset --hard "origin/$Branch"
} else {
  Info "Cloning QuickPatch ($Branch) into $Root..."
  git clone --depth 1 --branch $Branch $RepoUrl $Root
}

# Resolve a Dart SDK.
$Dart = $null
if (Get-Command dart -ErrorAction SilentlyContinue) {
  $Dart = (Get-Command dart).Source
} elseif (Get-Command flutter -ErrorAction SilentlyContinue) {
  $cand = Join-Path (Split-Path (Get-Command flutter).Source) 'cache\dart-sdk\bin\dart.exe'
  if (Test-Path $cand) { $Dart = $cand }
}
if (-not $Dart) { throw 'A Dart or Flutter SDK is required. Install Flutter (https://flutter.dev) and retry.' }

$Cache = Join-Path $BinDir 'cache'
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

Info 'Building quickpatch (one-time, ~30s)...'
Push-Location (Join-Path $Root 'quickpatch_cli')
& $Dart pub get | Out-Null
Pop-Location
& $Dart compile exe (Join-Path $Root 'quickpatch_cli\bin\quickpatch.dart') -o (Join-Path $Cache 'quickpatch.exe')
git -C $Root rev-parse HEAD | Out-File -Encoding ascii (Join-Path $Cache '.quickpatch.revision')

# Wrapper .cmd so `quickpatch` is callable from PATH.
$wrapper = Join-Path $BinDir 'quickpatch.cmd'
@"
@echo off
set QUICKPATCH_ROOT=%~dp0..
"%~dp0cache\quickpatch.exe" %*
"@ | Out-File -Encoding ascii $wrapper

if (-not (Test-Path (Join-Path $Cache 'quickpatch.exe'))) { throw 'Build failed: snapshot was not produced.' }
Ok "QuickPatch installed at $Root"
Info "The first 'quickpatch release'/'patch' downloads the pinned Flutter + iOS engine (one-time)."

if (-not ($env:Path -split ';' | Where-Object { $_ -eq $BinDir })) {
  Info "Add QuickPatch to your PATH:"
  Write-Host "    setx PATH `"$env:Path;$BinDir`""
  Info "Then open a new terminal and run: quickpatch --help"
}
