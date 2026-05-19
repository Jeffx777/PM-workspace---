#!/usr/bin/env pwsh
<#
.SYNOPSIS
    验证 rule-cross-ref.md 中所有文件引用的有效性，并检测未被覆盖的规则文件。

.DESCRIPTION
    三项检查：
    1. EXISTENCE  — 依赖图中引用的每个文件是否实际存在
    2. COVERAGE   — .agent/ 下所有文件是否都出现在依赖图中（防止新增文件漏录）
    3. GEMINI_SYNC — pm-workspace/GEMINI.md 与全局 ~/.gemini/GEMINI.md 的哈希是否一致

.PARAMETER WorkspaceRoot
    pm-workspace 根目录，默认从脚本位置推断（scripts/ -> pm-workspace/）

.PARAMETER CrossRefPath
    rule-cross-ref.md 的路径，默认为 .agent/policies/rule-cross-ref.md

.OUTPUTS
    CROSSREF:PASS   — 全部通过
    CROSSREF:WARN   — 有警告（未覆盖文件 / 同步不一致）
    CROSSREF:FAIL   — 有错误（引用文件不存在）

.EXAMPLE
    pwsh -File pm-workspace/scripts/validate-cross-ref.ps1
    pwsh -File pm-workspace/scripts/validate-cross-ref.ps1 -Verbose
#>

param(
    [string]$WorkspaceRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$CrossRefPath  = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── 路径解析 ─────────────────────────────────────────────────────────────────
if (-not $CrossRefPath) {
    $CrossRefPath = Join-Path $WorkspaceRoot ".agent\policies\rule-cross-ref.md"
}

if (-not (Test-Path $CrossRefPath)) {
    Write-Output "CROSSREF:FAIL"
    Write-Output "  [ERROR] rule-cross-ref.md not found at: $CrossRefPath"
    exit 1
}

$agentDir = Join-Path $WorkspaceRoot ".agent"

# ── 结果收集 ─────────────────────────────────────────────────────────────────
$errors   = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$infos    = [System.Collections.Generic.List[string]]::new()

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 1: EXISTENCE — 依赖图中所有引用文件是否存在
# ═══════════════════════════════════════════════════════════════════════════════

$content = Get-Content $CrossRefPath -Raw -Encoding UTF8

# 提取所有以 `.agent/`、`pm-workspace/`、`knowledge-base/`、`.antigravity/`、`GEMINI.md` 开头的路径引用
$pathPattern = '`([^`]*?\.(?:md|yaml|html|ps1|py))[`（（]'
$allMatches  = [regex]::Matches($content, $pathPattern)

$referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$checkedPaths = [System.Collections.Generic.List[object]]::new()

foreach ($m in $allMatches) {
    $rawPath = $m.Groups[1].Value.Trim()

    # 过滤明显不是文件路径的引用（如 `AUDIT:FAIL`、`staged` 等）
    if ($rawPath -notmatch '[/\\]' -and $rawPath -notmatch '^GEMINI\.md$') { continue }

    # 标准化：去掉开头的 `.agent/`、`pm-workspace/` 等前缀，映射到物理路径
    $resolvedPath = $null
    if ($rawPath -match '^\.agent[/\\]') {
        $resolvedPath = Join-Path $WorkspaceRoot $rawPath
    }
    elseif ($rawPath -match '^pm-workspace[/\\]') {
        $resolvedPath = Join-Path (Split-Path $WorkspaceRoot -Parent) $rawPath
    }
    elseif ($rawPath -match '^knowledge-base[/\\]') {
        $resolvedPath = Join-Path $WorkspaceRoot $rawPath
    }
    elseif ($rawPath -match '^\.antigravity[/\\]') {
        $resolvedPath = Join-Path $WorkspaceRoot $rawPath
    }
    elseif ($rawPath -eq 'GEMINI.md' -or $rawPath -match '^GEMINI\.md$') {
        $resolvedPath = Join-Path $WorkspaceRoot "GEMINI.md"
    }
    elseif ($rawPath -match '^scripts[/\\]') {
        $resolvedPath = Join-Path $WorkspaceRoot $rawPath
    }
    else {
        continue  # 无法解析的路径格式，跳过
    }

    # 通配符路径（如 `所有 .agent/agents/*/AGENT.md`）跳过精确检查
    if ($resolvedPath -match '\*') { continue }

    $key = $resolvedPath.ToLower()
    if ($referenced.Contains($key)) { continue }
    $referenced.Add($key) | Out-Null

    $exists = Test-Path $resolvedPath -PathType Leaf
    $checkedPaths.Add([pscustomobject]@{
        RawPath      = $rawPath
        ResolvedPath = $resolvedPath
        Exists       = $exists
    }) | Out-Null

    if (-not $exists) {
        $errors.Add("  [MISSING] $rawPath → $resolvedPath")
    }
}

$infos.Add("CHECK 1 (EXISTENCE): scanned $($checkedPaths.Count) unique file references")
$missingCount = @($checkedPaths | Where-Object { -not $_.Exists }).Count
if ($missingCount -eq 0) {
    $infos.Add("  ✓ All $($checkedPaths.Count) referenced files exist")
} else {
    $infos.Add("  ✗ $missingCount file(s) referenced but not found on disk")
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 2: COVERAGE — .agent/ 下所有 .md 文件是否都出现在依赖图中
# ═══════════════════════════════════════════════════════════════════════════════

$agentFiles = Get-ChildItem -Recurse -File -Filter "*.md" -LiteralPath $agentDir |
    Where-Object { $_.FullName -notmatch '\\examples\\' }  # 跳过 examples/ 目录

# 不包含独立交叉业务规则的纯索引/工具类文件，豁免 coverage 检查
$ignorePatterns = @(
    "\\README\.md`$",
    "\\catalog\\.*\.md`$",
    "\\commands\\.*\.md`$",
    "\\evals\\.*\.md`$",
    "\\skills\\diagram-.*\.md`$",
    "\\skills\\singlefile-to-dev.*\.md`$",
    "\\skills\\delivery-catalog-generator.*\.md`$",
    "\\skills\\web-researcher.*\.md`$"
)

$crossRefRaw = Get-Content $CrossRefPath -Raw -Encoding UTF8
$uncovered   = [System.Collections.Generic.List[string]]::new()

foreach ($file in $agentFiles) {
    # 构造相对路径（相对于 WorkspaceRoot），用 / 分隔
    $relPath = $file.FullName.Substring($WorkspaceRoot.Length + 1).Replace('\', '/')

    # 检查是否命中忽略名单
    $shouldIgnore = $false
    foreach ($pattern in $ignorePatterns) {
        if ($file.FullName -match $pattern) {
            $shouldIgnore = $true
            break
        }
    }
    if ($shouldIgnore) { continue }

    # 在 cross-ref 内容中搜索该路径
    if ($crossRefRaw -notmatch [regex]::Escape($relPath)) {
        $uncovered.Add($relPath) | Out-Null
    }
}

$infos.Add("CHECK 2 (COVERAGE): scanned $($agentFiles.Count) .md files under .agent/")
if ($uncovered.Count -eq 0) {
    $infos.Add("  ✓ All .agent/ files appear in rule-cross-ref.md")
} else {
    $infos.Add("  ⚠ $($uncovered.Count) file(s) under .agent/ not mentioned in rule-cross-ref.md:")
    foreach ($f in $uncovered) {
        $warnings.Add("  [UNCOVERED] $f")
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 3: GEMINI_SYNC — pm-workspace/GEMINI.md 与 ~/.gemini/GEMINI.md 一致性
# ═══════════════════════════════════════════════════════════════════════════════

$srcGemini    = Join-Path $WorkspaceRoot "GEMINI.md"
$globalGemini = Join-Path $env:USERPROFILE ".gemini\GEMINI.md"

$infos.Add("CHECK 3 (GEMINI_SYNC): comparing $srcGemini vs $globalGemini")

if (-not (Test-Path $srcGemini)) {
    $errors.Add("  [MISSING] pm-workspace/GEMINI.md not found")
}
elseif (-not (Test-Path $globalGemini)) {
    $warnings.Add("  [WARN] Global ~/.gemini/GEMINI.md not found — run sync-gemini-global.ps1 first")
}
else {
    $srcHash    = (Get-FileHash $srcGemini    -Algorithm SHA256).Hash
    $globalHash = (Get-FileHash $globalGemini -Algorithm SHA256).Hash
    if ($srcHash -eq $globalHash) {
        $infos.Add("  ✓ GEMINI.md is in sync (SHA256: $($srcHash.Substring(0,12))...)")
    }
    else {
        $warnings.Add("  [STALE] pm-workspace/GEMINI.md and ~/.gemini/GEMINI.md differ — run sync-gemini-global.ps1")
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 输出报告
# ═══════════════════════════════════════════════════════════════════════════════

$overall = if ($errors.Count -gt 0) { "FAIL" }
           elseif ($warnings.Count -gt 0) { "WARN" }
           else { "PASS" }

Write-Output "CROSSREF:$overall"
Write-Output ("--- SUMMARY ({0} errors, {1} warnings) ---" -f $errors.Count, $warnings.Count)

foreach ($line in $infos)    { Write-Output $line }
if ($errors.Count -gt 0) {
    Write-Output "--- ERRORS ---"
    foreach ($line in $errors)   { Write-Output $line }
}
if ($warnings.Count -gt 0) {
    Write-Output "--- WARNINGS ---"
    foreach ($line in $warnings) { Write-Output $line }
}

Write-Output ""
Write-Output "Tip: Run 'pwsh -File pm-workspace/scripts/validate-cross-ref.ps1' from repo root"

exit $(if ($overall -eq "FAIL") { 1 } else { 0 })

