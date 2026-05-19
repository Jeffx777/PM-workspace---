<#
.SYNOPSIS
    Output harness for artifact-level delivery checks.
.DESCRIPTION
    Verifies required companion files for PRD, demo, archive, and pattern outputs.
    Demo deliveries also run the dedicated SingleFile quality gate.
.PARAMETER ProjectPath
    Optional project directory. When omitted, the script scans projects from REGISTRY.md.
.PARAMETER TaskType
    One of: prd | demo | archive | pattern | all
#>

param(
    [string]$ProjectPath = "",
    [ValidateSet("prd", "demo", "archive", "pattern", "all")]
    [string]$TaskType = "all"
)

$ErrorCount = 0
$WarnCount = 0
$PassCount = 0
$Results = @()

function Write-Check {
    param(
        [string]$Status,
        [string]$Message,
        [string]$Detail = ""
    )

    switch ($Status) {
        "PASS" {
            Write-Host "  PASS  $Message" -ForegroundColor Green
            $script:PassCount++
        }
        "FAIL" {
            Write-Host "  FAIL  $Message" -ForegroundColor Red
            $script:ErrorCount++
        }
        "WARN" {
            Write-Host "  WARN  $Message" -ForegroundColor Yellow
            $script:WarnCount++
        }
    }

    if ($Detail) {
        $detailColor = if ($Status -eq "FAIL") { "DarkRed" } elseif ($Status -eq "WARN") { "DarkYellow" } else { "DarkGreen" }
        Write-Host "        $Detail" -ForegroundColor $detailColor
    }

    $script:Results += [PSCustomObject]@{
        Status = $Status
        Message = $Message
        Detail = $Detail
    }
}

function Invoke-SingleFilePrototypeCheck {
    param([string]$HtmlPath)

    $checkerPath = Join-Path (Split-Path $PSScriptRoot -Parent) "tools\singlefile\check-singlefile-prototype.py"
    if (-not (Test-Path $checkerPath)) {
        Write-Check "WARN" "SingleFile checker missing" "Expected checker at $checkerPath"
        return
    }

    $rawOutput = & python $checkerPath $HtmlPath --json 2>$null
    $checkerExit = $LASTEXITCODE

    if (-not $rawOutput) {
        Write-Check "FAIL" "SingleFile checker returned no output" "Checker: $checkerPath"
        return
    }

    try {
        $payload = $rawOutput | ConvertFrom-Json
    } catch {
        Write-Check "FAIL" "SingleFile checker output is not valid JSON" "Checker: $checkerPath"
        return
    }

    if ($checkerExit -eq 0) {
        Write-Check "PASS" "SingleFile quality gate passed" "File size: $($payload.size_bytes) bytes"
    }

    foreach ($check in $payload.checks) {
        $detail = $check.message
        if ($null -ne $check.count) {
            $detail = "$detail (count=$($check.count))"
        }

        if ($check.level -eq "blocking") {
            Write-Check "FAIL" "SingleFile gate blocked: $($check.id)" $detail
        } elseif ($check.level -eq "warning") {
            Write-Check "WARN" "SingleFile gate warning: $($check.id)" $detail
        }
    }
}

function Find-DemoFile {
    param([string]$ProjPath)

    $demoCandidates = @("demo_final.html", "Demo.html", "demo.html")
    foreach ($candidate in $demoCandidates) {
        $match = Get-ChildItem -Path $ProjPath -Filter $candidate -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    return $null
}

function Test-PrdHarness {
    param([string]$ProjPath)

    Write-Host "`n[PRD Harness] $ProjPath" -ForegroundColor Cyan

    $prdFile = Get-ChildItem -Path $ProjPath -Filter "PRD.md" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $prdFile) {
        $prdFile = Get-ChildItem -Path $ProjPath -Filter "prd.md" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -eq $prdFile) {
        Write-Check "FAIL" "PRD.md not found" "Expected a PRD.md or prd.md under $ProjPath"
        return
    }
    Write-Check "PASS" "PRD file exists" $prdFile.FullName

    $implNotesPath = Join-Path (Split-Path $prdFile.FullName) "implementation-notes.md"
    if (-not (Test-Path $implNotesPath)) {
        Write-Check "WARN" "implementation-notes.md missing" "Create it when the PRD contains APIs, fields, or technical constraints"
    } else {
        Write-Check "PASS" "implementation-notes.md exists" $implNotesPath
    }

    $prdContent = Get-Content $prdFile.FullName -Raw -Encoding UTF8
    $forbiddenPatterns = @(
        @{ Pattern = "(?i)(POST|GET|PUT|DELETE)\s+/api/"; Name = "API route" },
        @{ Pattern = "(?i)varchar|int\(|bigint|CREATE TABLE"; Name = "SQL schema details" },
        @{ Pattern = "##\s*Open Questions"; Name = "standalone open-questions section" }
    )

    foreach ($fp in $forbiddenPatterns) {
        if ($prdContent -match $fp.Pattern) {
            Write-Check "FAIL" "Forbidden content found in PRD: $($fp.Name)" "Move technical details into implementation-notes.md"
        }
    }

    $requiredSections = @("Background", "Goal", "Success Metric", "Acceptance", "背景", "目标", "成功指标", "验收")
    foreach ($section in $requiredSections) {
        if ($prdContent -match [regex]::Escape($section)) {
            Write-Check "PASS" "Required keyword found: $section"
        }
    }
}

function Test-DemoHarness {
    param([string]$ProjPath)

    Write-Host "`n[Demo Harness] $ProjPath" -ForegroundColor Cyan

    $demoFile = Find-DemoFile -ProjPath $ProjPath
    if ($null -eq $demoFile) {
        Write-Check "WARN" "Demo file not found" "Expected demo_final.html, Demo.html, or demo.html under $ProjPath"
        return
    }
    Write-Check "PASS" "Demo file exists" $demoFile.FullName

    $demoDir = Split-Path $demoFile.FullName
    $demoContent = Get-Content $demoFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue

    $replicationBrief = Test-Path (Join-Path $demoDir "replication-brief.md")
    $hasInlineReplication = $demoContent -match "REPLICATION BRIEF|Replication Brief|复刻说明"
    if ($replicationBrief) {
        Write-Check "PASS" "replication-brief.md exists"
    } elseif ($hasInlineReplication) {
        Write-Check "PASS" "Inline replication brief found in demo"
    } else {
        Write-Check "FAIL" "Replication brief missing" "Provide replication-brief.md or embed a REPLICATION BRIEF block"
    }

    $selfCriticFile = Test-Path (Join-Path $demoDir "11-replication-self-critic.md")
    $hasInlineSelfCritic = $demoContent -match "Self-Critic|self-critic|自评摘要"
    if ($selfCriticFile) {
        Write-Check "PASS" "11-replication-self-critic.md exists"
    } elseif ($hasInlineSelfCritic) {
        Write-Check "PASS" "Inline self-critic evidence found in demo"
    } else {
        Write-Check "WARN" "Self-critic evidence missing" "Keep 11-replication-self-critic.md or an inline summary"
    }

    $qualityReport = Get-ChildItem -Path $demoDir -Filter "*quality*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $hasInlineQuality = $demoContent -match "Quality Watcher|quality report|质量报告"
    if ($qualityReport) {
        Write-Check "PASS" "Quality report exists" $qualityReport.Name
    } elseif ($hasInlineQuality) {
        Write-Check "PASS" "Inline quality report found in demo"
    } else {
        Write-Check "WARN" "Quality report missing" "High-risk demos should retain quality-watcher evidence"
    }

    Invoke-SingleFilePrototypeCheck -HtmlPath $demoFile.FullName
}

function Test-ArchiveHarness {
    Write-Host "`n[Archive Harness] knowledge-base/archives/" -ForegroundColor Cyan

    $archivePath = ".\knowledge-base\archives"
    if (-not (Test-Path $archivePath)) {
        Write-Check "WARN" "archives directory missing" "Create knowledge-base/archives before archiving"
        return
    }

    $archiveFiles = Get-ChildItem -Path $archivePath -Filter "*.md" -ErrorAction SilentlyContinue
    if ($archiveFiles.Count -eq 0) {
        Write-Check "WARN" "archives directory is empty" "Completed work should be archived by the knowledge archivist flow"
        return
    }

    foreach ($file in $archiveFiles) {
        $content = Get-Content $file.FullName -Raw -Encoding UTF8
        $firstLine = Get-Content $file.FullName -Encoding UTF8 | Select-Object -First 1

        if ($firstLine -match "^>") {
            Write-Check "PASS" "$($file.Name): first line is a summary"
        } else {
            Write-Check "FAIL" "$($file.Name): first line is not a summary" "Expected the first line to start with >"
        }

        if ($content -match "scope:\s*(domain-specific|universal)") {
            Write-Check "PASS" "$($file.Name): scope tag exists"
        } else {
            Write-Check "WARN" "$($file.Name): scope tag missing" "Add scope: domain-specific or scope: universal"
        }
    }
}

function Test-PatternHarness {
    Write-Host "`n[Pattern Harness] knowledge-base/patterns/" -ForegroundColor Cyan

    $patternPath = ".\knowledge-base\patterns"
    if (-not (Test-Path $patternPath)) {
        Write-Check "WARN" "patterns directory missing"
        return
    }

    $patternFiles = Get-ChildItem -Path $patternPath -Filter "*.md" -Recurse -ErrorAction SilentlyContinue
    $warned = 0

    foreach ($file in $patternFiles) {
        $firstLine = Get-Content $file.FullName -Encoding UTF8 | Select-Object -First 1
        $firstLineClean = $firstLine -replace "^#\s*", "" -replace "^>\s*", ""
        if ($firstLineClean.Length -le 0 -or $firstLineClean.Length -gt 60) {
            Write-Check "WARN" "$($file.Name): first-line summary too long or empty" "Keep the first-line summary within 1-60 characters"
            $warned++
        }
    }

    if ($warned -eq 0) {
        Write-Check "PASS" "All pattern cards have a valid first-line summary" "Checked $($patternFiles.Count) files"
    }
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host " Output Harness Validation" -ForegroundColor White
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor White

$WorkspaceRoot = $PSScriptRoot | Split-Path
if (-not (Test-Path (Join-Path $WorkspaceRoot "GEMINI.md"))) {
    $WorkspaceRoot = Get-Location
}
Push-Location $WorkspaceRoot

try {
    if ($ProjectPath -ne "" -and (Test-Path $ProjectPath)) {
        if ($TaskType -eq "prd" -or $TaskType -eq "all") {
            Test-PrdHarness -ProjPath $ProjectPath
        }
        if ($TaskType -eq "demo" -or $TaskType -eq "all") {
            Test-DemoHarness -ProjPath $ProjectPath
        }
    } else {
        $registryPath = ".antigravity\projects\REGISTRY.md"
        if (Test-Path $registryPath) {
            $prdPaths = Get-Content $registryPath -Encoding UTF8 |
                Where-Object { $_ -match "prd:\s*(.+)$" } |
                ForEach-Object {
                    if ($_ -match "prd:\s*(.+)$") {
                        $matches[1].Trim().Trim([char]96)
                    }
                }

            foreach ($prdPath in $prdPaths) {
                $projDir = Split-Path $prdPath -ErrorAction SilentlyContinue
                if ($projDir -and (Test-Path $projDir)) {
                    if ($TaskType -eq "prd" -or $TaskType -eq "all") {
                        Test-PrdHarness -ProjPath $projDir
                    }
                    if ($TaskType -eq "demo" -or $TaskType -eq "all") {
                        Test-DemoHarness -ProjPath $projDir
                    }
                }
            }
        }
    }

    if ($TaskType -eq "archive" -or $TaskType -eq "all") {
        Test-ArchiveHarness
    }
    if ($TaskType -eq "pattern" -or $TaskType -eq "all") {
        Test-PatternHarness
    }
}
finally {
    Pop-Location
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host " Validation Summary" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "  PASS: $PassCount" -ForegroundColor Green
Write-Host "  WARN: $WarnCount" -ForegroundColor Yellow
Write-Host "  FAIL: $ErrorCount" -ForegroundColor Red

if ($ErrorCount -gt 0) {
    Write-Host "`nHARNESS:FAIL - Found $ErrorCount blocking issues" -ForegroundColor Red
    exit 1
}
if ($WarnCount -gt 0) {
    Write-Host "`nHARNESS:WARN - Found $WarnCount warnings" -ForegroundColor Yellow
    exit 0
}

Write-Host "`nHARNESS:PASS - All structure checks passed" -ForegroundColor Green
exit 0
