$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'lib\agent-library.ps1')

$workspaceRoot = Split-Path $PSScriptRoot -Parent
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-ErrorMessage {
  param([string]$Message)
  $errors.Add($Message) | Out-Null
}

function Add-WarningMessage {
  param([string]$Message)
  $warnings.Add($Message) | Out-Null
}

$registryRecords = Get-RoleRegistryRecords -WorkspaceRoot $workspaceRoot
$roleFiles = Get-AgentRoleFiles -WorkspaceRoot $workspaceRoot
$commandFiles = Get-AgentCommandFiles -WorkspaceRoot $workspaceRoot

$roleByName = @{}
foreach ($record in $registryRecords) {
  if ($roleByName.ContainsKey($record.name)) {
    Add-ErrorMessage "Duplicate role name in ROLE-REGISTRY.md: $($record.name)"
  } else {
    $roleByName[$record.name] = $record
  }

  $fullPath = Join-Path $workspaceRoot $record.source
  if (-not (Test-Path -LiteralPath $fullPath)) {
    Add-ErrorMessage "Registry source missing: $($record.source)"
  }
}

$registeredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($record in $registryRecords) {
  $registeredPaths.Add((Join-Path $workspaceRoot $record.source)) | Out-Null
}

foreach ($file in $roleFiles) {
  if (-not $registeredPaths.Contains($file.FullName)) {
    $relative = Get-RelativeWorkspacePath -Path $file.FullName -WorkspaceRoot $workspaceRoot
    Add-ErrorMessage "Role file not registered in ROLE-REGISTRY.md: $relative"
  }

  $frontmatter = Get-AgentLibraryFrontmatter -Path $file.FullName
  $relative = Get-RelativeWorkspacePath -Path $file.FullName -WorkspaceRoot $workspaceRoot
  if (-not $frontmatter) {
    Add-ErrorMessage "Role file missing frontmatter: $relative"
    continue
  }

  foreach ($required in @('name', 'description')) {
    if (-not ($frontmatter.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$frontmatter.$required)) {
      Add-ErrorMessage "Role file missing required field '$required': $relative"
    }
  }

  $missingRecommended = @()
  foreach ($recommended in @('type', 'intent', 'best_for', 'outputs', 'review_gate', 'estimated_time')) {
    if (-not ($frontmatter.PSObject.Properties.Name -contains $recommended)) {
      $missingRecommended += $recommended
    }
  }
  if ($missingRecommended.Count -gt 0) {
    Add-WarningMessage "Role file missing recommended fields [$($missingRecommended -join ', ')]: $relative"
  }

  $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  if ($content -match '知识资产/') {
    Add-WarningMessage "Legacy path alias '知识资产/' still present: $relative"
  }
}

$commandNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $commandFiles) {
  $frontmatter = Get-AgentLibraryFrontmatter -Path $file.FullName
  $relative = Get-RelativeWorkspacePath -Path $file.FullName -WorkspaceRoot $workspaceRoot

  if (-not $frontmatter) {
    Add-ErrorMessage "Command missing frontmatter: $relative"
    continue
  }

  foreach ($required in @('name', 'description', 'argument-hint', 'uses', 'outputs', 'review_gate', 'estimated_time')) {
    if (-not ($frontmatter.PSObject.Properties.Name -contains $required)) {
      Add-ErrorMessage "Command missing required field '$required': $relative"
      continue
    }

    $value = $frontmatter.$required
    if ($value -is [System.Array]) {
      if ($value.Count -eq 0) {
        Add-ErrorMessage "Command field '$required' cannot be empty: $relative"
      }
    } elseif ([string]::IsNullOrWhiteSpace([string]$value)) {
      Add-ErrorMessage "Command field '$required' cannot be empty: $relative"
    }
  }

  if ($frontmatter.name) {
    if (-not $commandNames.Add([string]$frontmatter.name)) {
      Add-ErrorMessage "Duplicate command name: $($frontmatter.name)"
    }
  }

  if ($frontmatter.uses -is [System.Array]) {
    foreach ($use in $frontmatter.uses) {
      if (-not $roleByName.ContainsKey($use)) {
        Add-ErrorMessage "Command $($frontmatter.name) references unknown role: $use"
      }
    }
  } elseif ($frontmatter.uses) {
    if (-not $roleByName.ContainsKey([string]$frontmatter.uses)) {
      Add-ErrorMessage "Command $($frontmatter.name) references unknown role: $($frontmatter.uses)"
    }
  }
}

if ($errors.Count -gt 0) {
  Write-Output "CHECK:FAIL"
  Write-Output "--- ERRORS ($($errors.Count)) ---"
  foreach ($item in $errors) {
    Write-Output "  [ERROR] $item"
  }
  if ($warnings.Count -gt 0) {
    Write-Output "--- WARNINGS ($($warnings.Count)) ---"
    foreach ($item in $warnings) {
      Write-Output "  [WARN] $item"
    }
  }
  exit 1
}

if ($warnings.Count -gt 0) {
  Write-Output "CHECK:PASS_WITH_WARNINGS"
  Write-Output "- Roles checked: $($roleFiles.Count)"
  Write-Output "- Commands checked: $($commandFiles.Count)"
  Write-Output "--- WARNINGS ($($warnings.Count)) ---"
  foreach ($item in $warnings) {
    Write-Output "  [WARN] $item"
  }
  exit 0
}

Write-Output "CHECK:PASS"
Write-Output "- Roles checked: $($roleFiles.Count)"
Write-Output "- Commands checked: $($commandFiles.Count)"
