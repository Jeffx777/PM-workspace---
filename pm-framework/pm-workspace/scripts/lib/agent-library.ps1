function Get-PmWorkspaceRoot {
  return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function Get-RelativeWorkspacePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
  )

  if ($Path.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $Path.Substring($WorkspaceRoot.Length).TrimStart([char[]]@('\', '/'))
  }

  return $Path
}

function Get-AgentLibraryFrontmatter {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ($content -notmatch "(?ms)^---\r?\n(.*?)\r?\n---") {
    return $null
  }

  $frontmatter = $Matches[1] -split "\r?\n"
  $data = [ordered]@{}
  $i = 0

  while ($i -lt $frontmatter.Count) {
    $line = $frontmatter[$i]
    if ([string]::IsNullOrWhiteSpace($line)) {
      $i++
      continue
    }

    if ($line -match '^([A-Za-z0-9_-]+):\s*(.*)$') {
      $key = $Matches[1]
      $rest = $Matches[2].Trim()

      if ($rest -in @('|', '>-', '>')) {
        $i++
        $buffer = [System.Collections.Generic.List[string]]::new()
        while ($i -lt $frontmatter.Count) {
          $next = $frontmatter[$i]
          if ($next -match '^[A-Za-z0-9_-]+:\s*' -and -not $next.StartsWith(' ')) {
            break
          }

          if ($next -match '^\s{2,}(.*)$') {
            $buffer.Add($Matches[1]) | Out-Null
          } elseif ([string]::IsNullOrWhiteSpace($next)) {
            $buffer.Add("") | Out-Null
          } else {
            break
          }

          $i++
        }

        $data[$key] = ($buffer -join "`n").Trim()
        continue
      }

      if ($rest -eq '') {
        $i++
        $items = [System.Collections.Generic.List[string]]::new()
        while ($i -lt $frontmatter.Count) {
          $next = $frontmatter[$i]
          if ($next -match '^\s*-\s+(.*)$') {
            $items.Add($Matches[1].Trim().Trim('"')) | Out-Null
            $i++
            continue
          }

          if ([string]::IsNullOrWhiteSpace($next)) {
            $i++
            continue
          }

          if ($next.StartsWith(' ')) {
            $i++
            continue
          }

          break
        }

        if ($items.Count -gt 0) {
          $data[$key] = @($items.ToArray())
        } else {
          $data[$key] = ''
        }
        continue
      }

      $data[$key] = $rest.Trim('"')
    }

    $i++
  }

  return [pscustomobject]$data
}

function Get-AgentRoleFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
  )

  return Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.agent') -Recurse -File |
    Where-Object {
      ($_.FullName -like "*\.agent\agents\*\AGENT.md") -or
      ($_.FullName -like "*\.agent\skills\*\SKILL.md") -or
      ($_.FullName -like "*\.agent\skills\skill-authoring-guide.md")
    }
}

function Get-AgentCommandFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
  )

  $commandDir = Join-Path $WorkspaceRoot '.agent\commands'
  if (-not (Test-Path -LiteralPath $commandDir)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $commandDir -File -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' })
}

function Get-RoleRegistryRecords {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
  )

  $registryPath = Join-Path $WorkspaceRoot '.agent\ROLE-REGISTRY.md'
  if (-not (Test-Path -LiteralPath $registryPath)) {
    throw "Role registry not found: $registryPath"
  }

  $records = [System.Collections.Generic.List[object]]::new()
  $rows = Get-Content -LiteralPath $registryPath -Encoding UTF8 | Where-Object { $_ -match '^\| (agent|skill)-' }

  foreach ($row in $rows) {
    $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
    if ($cells.Count -lt 9) {
      continue
    }

    $records.Add([pscustomobject]@{
      id = $cells[1]
      name = $cells[2]
      kind = $cells[3]
      route_status = $cells[4]
      default_entry = $cells[5]
      review_gate = $cells[6]
      responsibility = $cells[7]
      source = $cells[8].Trim('`')
    }) | Out-Null
  }

  return @($records.ToArray())
}
