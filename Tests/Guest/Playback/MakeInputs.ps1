param([string]$OutputRoot='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../../../..'))
if(!$OutputRoot){$OutputRoot=Join-Path $workspace 'Temp/PlaybackFixtures/Input'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot,$workspace)
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
$manifest=@{}
foreach($item in @(
 @{name='PCM57.WAV';rate=48000;channels=2;bits=16;frames=9600},
 @{name='CVT57.WAV';rate=44100;channels=1;bits=8;frames=8820},
 @{name='LONG57.WAV';rate=48000;channels=2;bits=16;frames=28800}
)) {
 $path=Join-Path $OutputRoot $item.name
 $frameBytes=[int]($item.channels*$item.bits/8);$dataBytes=$item.frames*$frameBytes
 $writer=[IO.BinaryWriter]::new([IO.File]::Create($path))
 try {
  $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32](36+$dataBytes))
  $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16)
  $writer.Write([uint16]1);$writer.Write([uint16]$item.channels);$writer.Write([uint32]$item.rate)
  $writer.Write([uint32]($item.rate*$frameBytes));$writer.Write([uint16]$frameBytes);$writer.Write([uint16]$item.bits)
  $writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([uint32]$dataBytes)
  for($frame=0;$frame -lt $item.frames;$frame++) {
   for($channel=0;$channel -lt $item.channels;$channel++) {
    $value=($frame*17+$channel*31+3)%256
    if($item.bits -eq 8){$writer.Write([byte]$value)}else{$writer.Write([int16](($value-128)*256))}
   }
  }
 } finally {$writer.Dispose()}
 $manifest[$item.name]=@{rate=$item.rate;channels=$item.channels;bits=$item.bits;frames=$item.frames;bytes=(Get-Item $path).Length;sha256=(Get-FileHash $path).Hash.ToLowerInvariant();expected_accepted_stereo_s16=$item.frames*4}
}
$manifest|ConvertTo-Json -Depth 5|Set-Content (Join-Path $OutputRoot 'manifest.json')
Write-Host ('Three PCM playback fixtures created: '+$OutputRoot)
