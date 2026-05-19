$ErrorActionPreference = "Stop"

function Normalize-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDirectory,
    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $expanded = $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

function Add-Finding {
  param(
    [System.Collections.Generic.List[string]]$Findings,
    [string]$Message
  )

  $Findings.Add($Message) | Out-Null
}

function To-DisplayPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  if ($Path.ToLower().StartsWith($Root.ToLower())) {
    return $Path.Substring($Root.Length).TrimStart([char[]]@('\', '/'))
  }

  return $Path
}

$workspaceRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $workspaceRoot -Parent
$workspaceAntigravityPath = Join-Path $workspaceRoot ".antigravity"
$repoShadowAntigravityPath = Join-Path $repoRoot ".antigravity"
$registryPath = Join-Path $workspaceRoot ".antigravity/projects/REGISTRY.md"
$roleRegistryPath = Join-Path $workspaceRoot ".agent/ROLE-REGISTRY.md"
$indexPath = Join-Path $workspaceRoot "knowledge-base/_index.md"
$readmePath = Join-Path $workspaceRoot "README.md"
$catalogCommandsPath = Join-Path $workspaceRoot ".agent\catalog\commands.md"
$commandsDir = Join-Path $workspaceRoot ".agent\commands"
$kbPatternsRoot = Join-Path $workspaceRoot "knowledge-base\patterns"
$findings = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$checkedProjects = [System.Collections.Generic.List[string]]::new()
$patternFilesCount = 0
$commandFilesCount = 0
$templateMode = -not (Test-Path -LiteralPath $registryPath)

# Collect all PROJECT.md files outside pm-workspace (reused across multiple checks)
$allProjectFilesOutside = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
  Where-Object {
    $_.Name -eq "PROJECT.md" -and
    $_.FullName -notlike "*\\pm-workspace\\*" -and
    $_.FullName -notlike "*\\.vscode\\*"
  })

if ($templateMode) {
  Add-Finding -Findings $warnings -Message "TEMPLATE_MODE: project REGISTRY.md not found; skipping private project registry checks"
}
if (-not (Test-Path -LiteralPath $roleRegistryPath)) {
  throw "Role registry not found: $roleRegistryPath"
}

# ============================================================
# Section: Workspace root shadow-path validation
# ============================================================

if (Test-Path -LiteralPath $repoShadowAntigravityPath) {
  $shadowItem = Get-Item -LiteralPath $repoShadowAntigravityPath -Force
  $workspaceResolved = (Get-Item -LiteralPath $workspaceAntigravityPath -Force).FullName
  $isReparsePoint = [bool]($shadowItem.Attributes -band [IO.FileAttributes]::ReparsePoint)

  if (-not $isReparsePoint) {
    Add-Finding -Findings $findings -Message "Shadow .antigravity directory exists at repo root: .antigravity (expected a junction to pm-workspace/.antigravity or no directory at all)"
  }
  else {
    $shadowTargets = @()
    if ($shadowItem.PSObject.Properties.Name -contains 'Target' -and $null -ne $shadowItem.Target) {
      if ($shadowItem.Target -is [System.Array]) {
        $shadowTargets = @($shadowItem.Target)
      }
      else {
        $shadowTargets = @([string]$shadowItem.Target)
      }
    }

    if ($shadowTargets.Count -eq 0) {
      Add-Finding -Findings $findings -Message "Repo-root .antigravity exists as a reparse point, but its target could not be resolved"
    }
    else {
      $targetMatches = $false
      foreach ($target in $shadowTargets) {
        if ([System.IO.Path]::IsPathRooted($target)) {
          $absoluteTarget = [System.IO.Path]::GetFullPath($target)
        }
        else {
          $absoluteTarget = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $target))
        }
        if ($absoluteTarget -eq $workspaceResolved) {
          $targetMatches = $true
          break
        }
      }

      if (-not $targetMatches) {
      Add-Finding -Findings $findings -Message "Repo-root .antigravity exists but does not resolve to pm-workspace/.antigravity"
      }
    }
  }
}

$registryLines = if ($templateMode) { @() } else { Get-Content -Encoding UTF8 $registryPath }
$projectRows = $registryLines | Where-Object { $_ -match '^\| project-' }
$roleRegistryLines = Get-Content -Encoding UTF8 $roleRegistryPath
$roleRows = $roleRegistryLines | Where-Object { $_ -match '^\| (agent|skill)-' }
$registeredRoleSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($row in $roleRows) {
  $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
  if ($cells.Count -lt 9) {
    Add-Finding -Findings $findings -Message "Malformed role registry row: $row"
    continue
  }

  $roleId = $cells[1]
  $sourcePath = $cells[8].Trim('`')
  if ([string]::IsNullOrWhiteSpace($sourcePath)) {
    Add-Finding -Findings $findings -Message "Role registry $roleId missing source path"
    continue
  }

  $absoluteSourcePath = Normalize-RelativePath -BaseDirectory $workspaceRoot -RelativePath $sourcePath
  if (-not (Test-Path -LiteralPath $absoluteSourcePath)) {
    Add-Finding -Findings $findings -Message "Role registry $roleId references missing source: $sourcePath"
    continue
  }

  $normalizedSource = To-DisplayPath -Path $absoluteSourcePath -Root $repoRoot
  $registeredRoleSources.Add($normalizedSource) | Out-Null
}

# ============================================================
# Section: Project structure + sync state checks
# ============================================================

$today = Get-Date

foreach ($row in $projectRows) {
  $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
  if ($cells.Count -lt 13) {
    Add-Finding -Findings $findings -Message "Malformed registry row: $row"
    continue
  }

  $projectId = $cells[1]
  if ($projectId -like 'project-{*') {
    continue
  }

  $projectDir = $cells[5].Trim('`')
  $projectFile = $cells[6].Trim('`')
  $prdFile = $cells[7].Trim('`')
  $demoFile = $cells[8].Trim('`')
  $pathsToCheck = @(
    @{ Label = "project directory"; Value = $projectDir; ExpectDirectory = $true },
    @{ Label = "PROJECT.md"; Value = $projectFile; ExpectDirectory = $false },
    @{ Label = "PRD"; Value = $prdFile; ExpectDirectory = $false },
    @{ Label = "Demo"; Value = $demoFile; ExpectDirectory = $false }
  )

  foreach ($item in $pathsToCheck) {
    if ([string]::IsNullOrWhiteSpace($item.Value) -or $item.Value -eq "-") {
      continue
    }

    $absolutePath = Normalize-RelativePath -BaseDirectory $repoRoot -RelativePath $item.Value
    if (-not (Test-Path -LiteralPath $absolutePath)) {
      Add-Finding -Findings $findings -Message "Registry $projectId references missing $($item.Label): $($item.Value)"
      continue
    }

    if ($item.ExpectDirectory -and -not (Get-Item -LiteralPath $absolutePath).PSIsContainer) {
      Add-Finding -Findings $findings -Message "Registry $projectId expects directory but found file: $($item.Value)"
    }
  }

  # --- Sync state staleness checks (WARN level) ---
  $syncStatus = $cells[12]
  $lastSyncRaw = $cells[11]
  $projectStatus = $cells[3]

  if ($projectStatus -ne "archived" -and $lastSyncRaw -match '^\d{4}-\d{2}-\d{2}$') {
    $lastSyncDate = [datetime]::ParseExact($lastSyncRaw, "yyyy-MM-dd", $null)
    $daysSinceSync = ($today - $lastSyncDate).Days

    if ($syncStatus -match 'project_to_knowledge\s*=\s*staged' -and $daysSinceSync -gt 5) {
      $level = if ($daysSinceSync -gt 7) { "HIGH" } else { "NORMAL" }
      Add-Finding -Findings $warnings -Message "STALE_STAGED [$level]: $projectId has project_to_knowledge=staged for $daysSinceSync days (last sync: $lastSyncRaw)"
    }

    if ($syncStatus -match 'knowledge_to_project\s*=\s*stale' -and $daysSinceSync -gt 3) {
      Add-Finding -Findings $warnings -Message "STALE_UNRESOLVED: $projectId has knowledge_to_project=stale for $daysSinceSync days (last sync: $lastSyncRaw)"
    }
  }

  $checkedProjects.Add($projectId) | Out-Null
}

# ============================================================
# Section: PROJECT.md existence in project-like directories
# ============================================================

$projectLikeDirs = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
  Where-Object {
    ($_.Name -ceq "prd.md" -or $_.Name -ceq "PRD.md") -and
    $_.FullName -notlike "*\\pm-workspace\\*" -and
    $_.FullName -notlike "*\\.vscode\\*"
  } |
  Select-Object -ExpandProperty DirectoryName -Unique

foreach ($dir in $projectLikeDirs) {
  $projectFile = Join-Path $dir "PROJECT.md"
  if (-not (Test-Path -LiteralPath $projectFile)) {
    $relativeDir = To-DisplayPath -Path $dir -Root $repoRoot
    Add-Finding -Findings $findings -Message "Project-like directory missing PROJECT.md: $relativeDir"
  }
}

# ============================================================
# Section: Role file registration check
# ============================================================

$roleFiles = Get-ChildItem -LiteralPath (Join-Path $workspaceRoot ".agent") -Recurse -File |
  Where-Object {
    ($_.FullName -like "*\.agent\agents\*\AGENT.md") -or
    ($_.FullName -like "*\.agent\skills\*\SKILL.md") -or
    ($_.FullName -like "*\.agent\skills\skill-authoring-guide.md")
  }

foreach ($roleFile in $roleFiles) {
  $displayPath = To-DisplayPath -Path $roleFile.FullName -Root $repoRoot
  if (-not $registeredRoleSources.Contains($displayPath)) {
    Add-Finding -Findings $findings -Message "Role file missing from ROLE-REGISTRY.md: $displayPath"
  }
}

# ============================================================
# Section: Broken PROJECT.md references in markdown files
# ============================================================

$markdownFiles = Get-ChildItem -LiteralPath $workspaceRoot -Recurse -File -Filter "*.md"
foreach ($file in $markdownFiles) {
  $content = Get-Content -Encoding UTF8 -Raw $file.FullName
  $refMatches = [regex]::Matches($content, '`([^`]*PROJECT\.md)`')
  foreach ($match in $refMatches) {
    $relativePath = $match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -eq 'PROJECT.md' -or $relativePath.Contains('{')) {
      continue
    }

    if ($relativePath.StartsWith('./') -or $relativePath.StartsWith('.\') -or $relativePath.StartsWith('../') -or $relativePath.StartsWith('..\')) {
      $baseDirectory = $file.DirectoryName
    } else {
      $baseDirectory = $repoRoot
    }

    $absolutePath = Normalize-RelativePath -BaseDirectory $baseDirectory -RelativePath $relativePath
    if (-not (Test-Path -LiteralPath $absolutePath)) {
      $relativeFile = To-DisplayPath -Path $file.FullName -Root $repoRoot
      Add-Finding -Findings $findings -Message "Broken PROJECT.md reference in $relativeFile -> $relativePath"
    }
  }
}

# ============================================================
# Section: Route target validation (_index.md)
# Uses StringComparison.Ordinal to avoid culture-aware IndexOf issues
# ============================================================

if (Test-Path -LiteralPath $indexPath) {
  $indexContent = Get-Content -Encoding UTF8 $indexPath
  $kbRoot = Join-Path $workspaceRoot "knowledge-base"
  $arrowStr = [string][char]0x2192  # →
  $dashStr = [string][char]0x2014   # —
  $passedSeparator = $false

  foreach ($line in $indexContent) {
    if ($line -match '^\s*---\s*$') {
      $passedSeparator = $true
    }
    if ($passedSeparator -or $line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    if ($line.Contains($arrowStr) -and $line.Contains($dashStr)) {
      $arrowChar = [char]0x2192
      $dashChar = [char]0x2014
      $parts = $line.Split($arrowChar)
      if ($parts.Count -lt 2) { continue }
      
      $afterArrow = $parts[1..($parts.Count-1)] -join $arrowChar
      $dashParts = $afterArrow.Split($dashChar)
      if ($dashParts.Count -lt 2) { continue }

      $between = $dashParts[0].Trim()
      $routeTarget = ($between -split '\s')[0]

      if ([string]::IsNullOrWhiteSpace($routeTarget) -or $routeTarget.Contains('{') -or $routeTarget.StartsWith('#')) {
        continue
      }

      $absoluteTarget = Normalize-RelativePath -BaseDirectory $kbRoot -RelativePath $routeTarget
      if (-not (Test-Path -LiteralPath $absoluteTarget)) {
        Add-Finding -Findings $warnings -Message "EMPTY_ROUTE_TARGET: _index.md routes to missing path: $routeTarget"
        continue
      }

      $targetItem = Get-Item -LiteralPath $absoluteTarget
      if ($targetItem.PSIsContainer) {
        $allFiles = @(Get-ChildItem -LiteralPath $absoluteTarget -File -Recurse -ErrorAction SilentlyContinue)
        if ($allFiles.Count -eq 0) {
          Add-Finding -Findings $warnings -Message "EMPTY_ROUTE_TARGET: _index.md routes to empty directory: $routeTarget (no files)"
        } else {
          $contentFiles = @($allFiles | Where-Object { $_.Name -ne '_template.md' -and $_.Name -ne 'README.md' })
          if ($contentFiles.Count -eq 0) {
            Add-Finding -Findings $warnings -Message "EMPTY_ROUTE_TARGET: _index.md routes to empty directory: $routeTarget (only templates/READMEs)"
          }
        }
      }
    }
  }
}

# ============================================================
# Section: README.md "当前已接入项目" completeness
# Every PROJECT.md outside pm-workspace must be listed in README.md
# ============================================================

if (Test-Path -LiteralPath $readmePath) {
  $readmeContent = Get-Content -Encoding UTF8 -Raw $readmePath
  foreach ($pf in $allProjectFilesOutside) {
    $relPath = (To-DisplayPath -Path $pf.FullName -Root $repoRoot).Replace('\', '/')
    if (-not $readmeContent.Contains($relPath)) {
      Add-Finding -Findings $findings -Message "README.md 「当前已接入项目」缺少条目: $relPath"
    }
  }
} else {
  Add-Finding -Findings $findings -Message "pm-workspace/README.md 文件不存在"
}

# ============================================================
# Section: REGISTRY.md reverse coverage
# Every PROJECT.md outside pm-workspace must have a row in REGISTRY.md
# (Complements the existing forward check: REGISTRY row → file existence)
# ============================================================

if (-not $templateMode) {
  $registryContentRaw = Get-Content -Encoding UTF8 -Raw $registryPath
  foreach ($pf in $allProjectFilesOutside) {
    $relPath = (To-DisplayPath -Path $pf.FullName -Root $repoRoot).Replace('\', '/')
    if (-not $registryContentRaw.Contains($relPath)) {
      Add-Finding -Findings $findings -Message "REGISTRY.md 缺少项目注册行: $relPath"
    }
  }
}

# ============================================================
# Section: knowledge-base/_index.md pattern coverage
# Every .md in patterns/ (excl. _template.md, README.md, _universal-index.md)
# must be referenced by filename or relative path in _index.md
# ============================================================

if ((Test-Path -LiteralPath $indexPath) -and (Test-Path -LiteralPath $kbPatternsRoot)) {
  $indexContentRaw = Get-Content -Encoding UTF8 -Raw $indexPath
  $patternFiles = Get-ChildItem -LiteralPath $kbPatternsRoot -Recurse -File -Filter "*.md" |
    Where-Object { $_.Name -ne '_template.md' -and $_.Name -ne 'README.md' -and $_.Name -ne '_universal-index.md' }
  $patternFilesCount = @($patternFiles).Count
  foreach ($pf in $patternFiles) {
    $relPath = (To-DisplayPath -Path $pf.FullName -Root (Join-Path $workspaceRoot "knowledge-base")).Replace('\', '/')
    $relDir  = (To-DisplayPath -Path $pf.DirectoryName -Root (Join-Path $workspaceRoot "knowledge-base")).Replace('\', '/')
    # A file is "indexed" if: its basename, its full relPath, OR its parent directory path (with trailing /) appears in _index.md
    $coveredByDir = $indexContentRaw.Contains($relDir + "/")
    if (-not $indexContentRaw.Contains($pf.BaseName) -and -not $indexContentRaw.Contains($relPath) -and -not $coveredByDir) {
      Add-Finding -Findings $warnings -Message "UNINDEXED_PATTERN: _index.md 缺少 pattern 路由: $relPath"
    }
  }
}

# ============================================================
# Section: .agent/catalog/commands.md command coverage
# Every .md in .agent/commands/ (excl. README.md) must appear in catalog/commands.md
# ============================================================

if ((Test-Path -LiteralPath $catalogCommandsPath) -and (Test-Path -LiteralPath $commandsDir)) {
  $catalogCommandsContent = Get-Content -Encoding UTF8 -Raw $catalogCommandsPath
  $commandFiles = Get-ChildItem -LiteralPath $commandsDir -File -Filter "*.md" |
    Where-Object { $_.Name -ne 'README.md' }
  $commandFilesCount = @($commandFiles).Count
  foreach ($cf in $commandFiles) {
    if (-not $catalogCommandsContent.Contains($cf.BaseName) -and -not $catalogCommandsContent.Contains($cf.Name)) {
      Add-Finding -Findings $warnings -Message "UNINDEXED_COMMAND: .agent/catalog/commands.md 缺少命令条目: $($cf.Name)"
    }
  }
}

# ============================================================
# Section: scripts/ compliance check (script-policy.md)
# ============================================================

$scriptsDir = Join-Path $workspaceRoot "scripts"
$toolsDir   = Join-Path $workspaceRoot "tools"

foreach ($checkDir in @($scriptsDir, $toolsDir)) {
  if (-not (Test-Path -LiteralPath $checkDir)) { continue }
  $dirLabel = To-DisplayPath -Path $checkDir -Root $workspaceRoot

  # __pycache__ is a build artifact — should never be committed
  $pycacheDirs = @(Get-ChildItem -LiteralPath $checkDir -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq '__pycache__' })
  foreach ($dir in $pycacheDirs) {
    $rel = To-DisplayPath -Path $dir.FullName -Root $workspaceRoot
    Add-Finding -Findings $findings -Message "SCRIPT_POLICY: build artifact in $dirLabel`: $rel (delete or add to .gitignore)"
  }

  # Non-script files (.html, .htm, etc.) do not belong here
  $nonScriptFiles = @(Get-ChildItem -LiteralPath $checkDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -notin @('.ps1', '.py', '.md', '.json', '.yaml', '.yml', '.txt', '.gitkeep') -and $_.Name -ne '.gitkeep' })
  foreach ($file in $nonScriptFiles) {
    $rel = To-DisplayPath -Path $file.FullName -Root $workspaceRoot
    Add-Finding -Findings $warnings -Message "SCRIPT_POLICY: non-script file in $dirLabel`: $rel"
  }
}

# Python files in scripts/ must not exist (Python tools go to tools/)
$pyInScripts = @(Get-ChildItem -LiteralPath $scriptsDir -File -Filter "*.py" -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notlike "*__pycache__*" })
foreach ($pyFile in $pyInScripts) {
  $rel = To-DisplayPath -Path $pyFile.FullName -Root $workspaceRoot
  Add-Finding -Findings $warnings -Message "SCRIPT_POLICY: Python file in scripts/ (should be in tools/): $rel"
}

# Python files in tools/ must not have hardcoded absolute paths (临时脚本特征)
if (Test-Path -LiteralPath $toolsDir) {
  $pyInTools = @(Get-ChildItem -LiteralPath $toolsDir -File -Filter "*.py" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "*__pycache__*" })
  foreach ($pyFile in $pyInTools) {
    $content = Get-Content -LiteralPath $pyFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($content -match "r'[A-Za-z]:\\" -or $content -match 'r"[A-Za-z]:\\' -or
        $content -match "open\(r'原型" -or $content -match "Path\(r'原型") {
      $rel = To-DisplayPath -Path $pyFile.FullName -Root $workspaceRoot
      Add-Finding -Findings $warnings -Message "SCRIPT_POLICY: $rel 含硬编码绝对路径，疑为临时脚本（应放 .antigravity/workspaces/）"
    }
  }
}

# ============================================================
# Output
# ============================================================

if ($findings.Count -gt 0) {
  Write-Output "AUDIT:FAIL"
  Write-Output "--- ERRORS ($($findings.Count)) ---"
  foreach ($finding in $findings) {
    Write-Output "  [ERROR] $finding"
  }
  if ($warnings.Count -gt 0) {
    Write-Output "--- WARNINGS ($($warnings.Count)) ---"
    foreach ($warning in $warnings) {
      Write-Output "  [WARN] $warning"
    }
  }
  exit 1
}

if ($warnings.Count -gt 0) {
  Write-Output "AUDIT:PASS_WITH_WARNINGS"
  Write-Output "- Registered projects checked: $($checkedProjects.Count)"
  Write-Output "- Project-like directories checked: $($projectLikeDirs.Count)"
  Write-Output "- Markdown PROJECT references checked: $($markdownFiles.Count)"
  Write-Output "- PROJECT.md files outside workspace checked: $($allProjectFilesOutside.Count)"
  Write-Output "- Pattern files in knowledge-base checked: $patternFilesCount"
  Write-Output "- Command files in .agent/commands checked: $commandFilesCount"
  Write-Output "--- WARNINGS ($($warnings.Count)) ---"
  foreach ($warning in $warnings) {
    Write-Output "  [WARN] $warning"
  }
  exit 0
}

Write-Output "AUDIT:PASS"
Write-Output "- Registered projects checked: $($checkedProjects.Count)"
Write-Output "- Project-like directories checked: $($projectLikeDirs.Count)"
Write-Output "- Markdown PROJECT references checked: $($markdownFiles.Count)"
Write-Output "- PROJECT.md files outside workspace checked: $($allProjectFilesOutside.Count)"
Write-Output "- Pattern files in knowledge-base checked: $patternFilesCount"
Write-Output "- Command files in .agent/commands checked: $commandFilesCount"


