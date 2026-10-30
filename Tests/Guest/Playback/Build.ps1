param([string]$OutputRoot='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=[IO.Path]::GetFullPath($PSScriptRoot)
$workspace=[IO.Path]::GetFullPath((Join-Path $project '../../../../../..'))
if(!$OutputRoot){$OutputRoot=Join-Path $workspace 'Temp/PlaybackFixtures'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot,$workspace)
$sdk=Join-Path $workspace 'Repositories/SDK'
$zig=Join-Path $workspace ('DevKit/Toolchains/Zig/zig'+$(if($IsWindows){'.exe'}else{''}))
Push-Location $sdk
try {
 & $zig build --build-file (Join-Path $sdk 'Tools/ManifestProject/build.zig') ('--fork='+(Join-Path $workspace 'Repositories/Contract')) ('-Dproject-root='+$project) --cache-dir (Join-Path $OutputRoot 'Cache') --prefix (Join-Path $OutputRoot 'Artifacts') -j2 --summary all
 if($LASTEXITCODE -ne 0){throw 'PCM playback observer build failed'}
} finally {Pop-Location}
