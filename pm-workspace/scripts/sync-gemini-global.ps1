param(
  [string]$SourcePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "GEMINI.md"),
  [string]$TargetPath = (Join-Path $env:USERPROFILE ".gemini\GEMINI.md")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
  throw "Source GEMINI.md not found: $SourcePath"
}

$targetDir = Split-Path -Parent $TargetPath
if (-not (Test-Path -LiteralPath $targetDir)) {
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$targetItem = Get-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
if ($targetItem -and ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  Remove-Item -LiteralPath $TargetPath -Force
  $targetItem = $null
}

$sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
$targetHash = $null

if ($targetItem -and (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
  $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
}

if ($sourceHash -eq $targetHash) {
  Write-Output "SYNC:NOOP"
  Write-Output ("- source={0}" -f $SourcePath)
  Write-Output ("- target={0}" -f $TargetPath)
  return
}

$tempPath = Join-Path $targetDir "GEMINI.md.tmp"
Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
Move-Item -LiteralPath $tempPath -Destination $TargetPath -Force

$syncedHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
if ($syncedHash -ne $sourceHash) {
  throw "Sync verification failed: target hash mismatch."
}

Write-Output "SYNC:OK"
Write-Output ("- source={0}" -f $SourcePath)
Write-Output ("- target={0}" -f $TargetPath)
Write-Output ("- sha256={0}" -f $sourceHash)
