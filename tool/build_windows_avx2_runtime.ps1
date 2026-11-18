param([Parameter(Mandatory = $true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$build = Join-Path $env:RUNNER_TEMP 'aivexus-cpu-avx2-recovery'
$destination = Join-Path $ReleaseDir 'runtime-cpu-avx2'
& cmake -S (Join-Path $root 'native/windows/cpu_avx2') -B $build -A x64 "-DCMAKE_INSTALL_PREFIX=$destination"
if ($LASTEXITCODE -ne 0) { throw 'AVX2 configure failed' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msbuild = Join-Path $vs 'MSBuild/Current/Bin/MSBuild.exe'
$projects = @(Get-ChildItem -LiteralPath $build -Filter 'llama-completion.vcxproj' -File -Recurse)
if ($projects.Count -ne 1) { throw 'Missing or ambiguous completion project' }
& $msbuild $projects[0].FullName '/m:2' '/p:Configuration=Release' '/p:Platform=x64'
if ($LASTEXITCODE -ne 0) { throw 'AVX2 build failed' }
& cmake --install $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'AVX2 install into bundle failed' }
if (!(Test-Path -LiteralPath (Join-Path $destination 'llama-completion.exe'))) { throw 'AVX2 helper absent' }
