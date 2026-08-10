<#
.SYNOPSIS
  Build the nitro_http `windows-x64` dependency slice.

.DESCRIPTION
  The Windows counterpart of build.sh. Produces
  out\nitro-curl-windows-x64.tar.gz containing lib\, include\ and manifest.json,
  which is exactly what src/deps.cmake downloads and extracts.

  Toolchain: Visual Studio 2022 (x64 native tools), NASM, Go, git, CMake, Ninja.

  Ninja — not the Visual Studio generator. BoringSSL's own BUILDING.md states
  that the generated .vcxproj files contain no rule for assembling its assembly
  sources, so a VS-generator build links against a stub-free but incomplete
  libcrypto. Ninja drives ml64/nasm correctly.

  Everything compiles with /MD in every configuration (see
  CMAKE_MSVC_RUNTIME_LIBRARY in CMakeLists.txt): the plugin DLL is a
  self-contained C-ABI island and must not inherit the consuming app's /MDd.

.EXAMPLE
  pwsh tool\deps\build.ps1
.EXAMPLE
  pwsh tool\deps\build.ps1 -NoHttp3 -Jobs 8
#>
[CmdletBinding()]
param(
  [string] $Out,
  [ValidateSet('x64')]
  [string] $Arch = 'x64',
  [switch] $NoHttp3,
  [switch] $Clean,
  [int]    $Jobs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $Here 'out' }

function Die([string] $Message) {
  Write-Host ''
  Write-Host "build.ps1: $Message" -ForegroundColor Red
  Write-Host ''
  exit 1
}

function Invoke-Checked([string] $What, [scriptblock] $Block) {
  & $Block
  if ($LASTEXITCODE -ne 0) { Die "$What failed with exit code $LASTEXITCODE" }
}

# Not `$IsWindows`: that automatic variable does not exist in Windows
# PowerShell 5.1, and Set-StrictMode turns reading it into a hard error there.
if ($env:OS -ne 'Windows_NT') {
  Die 'build.ps1 only builds the Windows slice; use build.sh on macOS and Linux.'
}

# ── Visual Studio environment ────────────────────────────────────────────────
# Importing VsDevCmd is what puts cl.exe, link.exe and the Windows SDK on PATH.
# Skipped when the caller is already inside a developer shell (or when CI used
# ilammy/msvc-dev-cmd), so running this twice is harmless.
if (-not $env:VCToolsInstallDir) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) {
    Die @'
Visual Studio 2022 was not found (no vswhere.exe).

  Install the "Desktop development with C++" workload:
    winget install Microsoft.VisualStudio.2022.BuildTools ^
      --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
'@
  }

  $vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
  if (-not $vsPath) {
    Die 'vswhere found no Visual Studio install with the C++ toolset (VC.Tools.x86.x64).'
  }

  $devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
  if (-not (Test-Path $devCmd)) { Die "VsDevCmd.bat missing under $vsPath" }

  Write-Host "==> importing MSVC environment from $vsPath"
  & cmd.exe /c "`"$devCmd`" -arch=amd64 -host_arch=amd64 -no_logo && set" |
    ForEach-Object {
      if ($_ -match '^([^=]+)=(.*)$') {
        # -LiteralPath: names such as ProgramFiles(x86) contain characters the
        # provider would otherwise treat as wildcards.
        Set-Item -LiteralPath ("Env:" + $matches[1]) -Value $matches[2]
      }
    }
  if (-not $env:VCToolsInstallDir) { Die 'VsDevCmd.bat ran but did not set VCToolsInstallDir.' }
}

# ── Required tools ───────────────────────────────────────────────────────────
$required = @{
  'cmake' = 'winget install Kitware.CMake';
  'ninja' = 'winget install Ninja-build.Ninja';
  'git'   = 'winget install Git.Git';
  'go'    = 'winget install GoLang.Go   (BoringSSL verifies its symbol prefixing with Go)';
  'nasm'  = 'winget install NASM.NASM   (BoringSSL assembles its x86-64 crypto with NASM)';
  'tar'   = 'ships with Windows 10 1803 and newer';
}
foreach ($tool in $required.Keys) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Die "'$tool' was not found on PATH.`n`n  Install it: $($required[$tool])"
  }
}

# The superbuild drives BoringSSL through tool/deps/prefix_symbols.sh so there
# is one implementation of the prefixing flow. Git for Windows supplies bash.
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
  Die @'
'bash' was not found on PATH.

  BoringSSL is built through tool/deps/prefix_symbols.sh, which needs a POSIX
  shell. Git for Windows ships one; add its usr\bin to PATH, e.g.

    $env:PATH = "C:\Program Files\Git\usr\bin;$env:PATH"
'@
}

if ($Jobs -le 0) {
  $Jobs = [int] $env:NUMBER_OF_PROCESSORS
  if ($Jobs -le 0) { $Jobs = 2 }
}

$slice     = "windows-$Arch"
$buildDir  = Join-Path $Out "build\$slice"
$stageDir  = Join-Path $Out "stage\$slice"
$http3     = if ($NoHttp3) { 'OFF' } else { 'ON' }

if ($Clean) {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $buildDir, $stageDir
}
New-Item -ItemType Directory -Force -Path $buildDir, $stageDir, $Out | Out-Null

# CMake wants forward slashes; a backslash in -DCMAKE_INSTALL_PREFIX is an
# escape sequence by the time a sub-build re-parses the cache.
$stageCMake = (Resolve-Path $stageDir).Path -replace '\\', '/'

Write-Host "==> nitro_http deps: $slice (http3=$http3, generator=Ninja, jobs=$Jobs)"

$nasm = (Get-Command nasm).Source -replace '\\', '/'

Invoke-Checked 'cmake configure' {
  cmake -S $Here -B $buildDir -G Ninja `
    "-DCMAKE_BUILD_TYPE=Release" `
    "-DCMAKE_INSTALL_PREFIX=$stageCMake" `
    "-DNITRO_HTTP_ENABLE_HTTP3=$http3" `
    "-DCMAKE_ASM_NASM_COMPILER=$nasm"
}

Invoke-Checked 'cmake build' {
  cmake --build $buildDir --parallel $Jobs
}

# ── Sanity-check the staged tree ─────────────────────────────────────────────
foreach ($needed in @('include\curl\curl.h', 'manifest.json')) {
  $p = Join-Path $stageDir $needed
  if (-not (Test-Path $p)) { Die "build finished but $p is missing — the slice is unusable" }
}
if (-not (Get-ChildItem -Path (Join-Path $stageDir 'lib') -File -ErrorAction SilentlyContinue)) {
  Die "build finished but $stageDir\lib is empty"
}
if (-not (Test-Path (Join-Path $stageDir 'lib\libcurl.lib'))) {
  Die "build finished but lib\libcurl.lib is missing — src/deps.cmake would not resolve this slice"
}

# ── Package ──────────────────────────────────────────────────────────────────
$tarball = Join-Path $Out "nitro-curl-$slice.tar.gz"
Remove-Item -Force -ErrorAction SilentlyContinue $tarball
# Windows' own tar (bsdtar, System32) handles `D:\...` paths; the GNU tar that
# Git for Windows puts on PATH parses the drive letter as a REMOTE HOSTNAME
# ("Cannot connect to D: resolve failed") and dies. CI prepends Git's usr\bin
# for the POSIX tools prefix_symbols.sh needs, so name the right tar explicitly
# rather than depending on PATH order.
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tarExe)) { $tarExe = 'tar' }
Invoke-Checked 'tar' {
  & $tarExe -czf $tarball -C $stageDir lib include manifest.json
}

$size = (Get-Item $tarball).Length
if ($size -lt 100000) {
  Die "produced $tarball but it is only $size bytes — refusing to publish"
}

Write-Host "==> $tarball ($size bytes)"
