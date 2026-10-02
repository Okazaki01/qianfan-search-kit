<#
.SYNOPSIS
  安装 / 卸载「百度千帆联网搜索」到 DeepSeek Harness（技能脚本 + MCP 原生工具）。

.DESCRIPTION
  做三件事，全部幂等、可回退：
    1. 把 payload 里的技能目录复制到 <DSH_HOME>/skills/qianfan-search
    2. 准备 config.json（已有则保留；-Key 可写入/更新密钥）
    3. 给每个 profile 的 cordis.patch.yml 追加一段「托管块」，把 MCP 服务接进
       dsh-mcp-client（块有开始/结束标记，卸载时精确移除；改动前自动备份）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1                       # 自动探测并安装到所有 profile
  powershell -ExecutionPolicy Bypass -File install.ps1 -Key "<你的千帆-API-Key>"   # 顺便写入密钥
  powershell -ExecutionPolicy Bypass -File install.ps1 -Profiles web-desktop     # 只装到指定 profile
  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall                # 卸载接线（保留技能目录）
  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall -RemoveSkill   # 连同技能目录一起删除
#>
[CmdletBinding()]
param(
  [string]   $DshHome,
  [string]   $Key,
  [string[]] $Profiles = @(),
  [string]   $NodePath,
  [switch]   $Uninstall,
  [switch]   $RemoveSkill,
  [switch]   $SkipVerify,
  [string]   $ServerName = 'qianfan'
)

$ErrorActionPreference = 'Stop'
$BEGIN = '# >>> qianfan-search MCP（本块由 install.ps1 管理，请勿手动编辑内部）>>>'
$END   = '# <<< qianfan-search MCP <<<'
$SKILL = 'qianfan-search'

function Write-Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "   [OK] $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "   [!]  $t" -ForegroundColor Yellow }

function Write-Json {
  param([string]$Path, $Object)
  $json = $Object | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ── 1. 解析 DSH_HOME ────────────────────────────────────────────────
if (-not $DshHome) {
  if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
  else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
if (-not (Test-Path $DshHome)) {
  throw "找不到 DSH_HOME：$DshHome（可用 -DshHome 指定）"
}
Write-Step "DSH_HOME = $DshHome"

$skillDir  = Join-Path $DshHome "skills\$SKILL"
$profilesDir = Join-Path $DshHome 'profiles'
$payload   = Join-Path $PSScriptRoot "payload\skills\$SKILL"

# ── 2. 探测 Node ───────────────────────────────────────────────────
function Resolve-Node {
  param([string]$Explicit)
  if ($Explicit) {
    if (Test-Path $Explicit) { return $Explicit }
    throw "指定的 Node 不存在：$Explicit"
  }
  # DSH 托管运行时（多版本时取第一个可用的）
  $rt = Join-Path $DshHome 'dsh-runtimes'
  if (Test-Path $rt) {
    $cand = @(Get-ChildItem $rt -Directory -ErrorAction SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'dependencies\node\bin\node.exe' } |
              Where-Object { Test-Path $_ })
    if ($cand.Count -gt 0) { return $cand[0] }
  }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

Write-Step '探测 Node 运行时'
$node = Resolve-Node -Explicit $NodePath
if ($node) { Write-Ok "Node: $node" }
else       { Write-Warn2 '没找到 Node；MCP 服务需要它。请用 -NodePath 指定 node.exe 的绝对路径' }

# ── 3. 卸载分支 ────────────────────────────────────────────────────
function Get-ProfilePatches {
  param([string[]]$Only)
  if ($Only.Count -gt 0) {
    return $Only | ForEach-Object { Join-Path $profilesDir "$_\cordis.patch.yml" } |
           Where-Object { Test-Path $_ }
  }
  if (-not (Test-Path $profilesDir)) { return @() }
  return Get-ChildItem $profilesDir -Directory -ErrorAction SilentlyContinue |
         ForEach-Object { Join-Path $_.FullName 'cordis.patch.yml' } |
         Where-Object { Test-Path $_ }
}

function Remove-ManagedBlock {
  param([string]$Path)
  $text = [System.IO.File]::ReadAllText($Path)
  $pattern = "(?ms)^" + [regex]::Escape($BEGIN) + ".*?^" + [regex]::Escape($END) + "\r?\n?"
  if ($text -notmatch [regex]::Escape($BEGIN)) { return $false }
  $new = [regex]::Replace($text, $pattern, '')
  $new = $new.TrimEnd() + [Environment]::NewLine
  [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
  return $true
}

if ($Uninstall) {
  Write-Step '卸载：移除 profile 里的托管块'
  $touched = 0
  foreach ($p in Get-ProfilePatches -Only $Profiles) {
    if (Remove-ManagedBlock -Path $p) { Write-Ok "已清理 $p"; $touched++ }
    else { Write-Host "   -  无需处理（没有托管块）：$p" }
  }
  if ($touched -eq 0) { Write-Warn2 '没有找到需要清理的托管块' }
  if ($RemoveSkill) {
    Write-Step '删除技能目录'
    if (Test-Path $skillDir) { Remove-Item $skillDir -Recurse -Force; Write-Ok "已删除 $skillDir" }
    else { Write-Warn2 "技能目录不存在：$skillDir" }
  } else {
    Write-Host "`n   （技能目录保留：$skillDir；要一起删就加 -RemoveSkill）"
  }
  Write-Host "`n完成。重启 DeepSeek Harness 后生效。" -ForegroundColor Cyan
  exit 0
}

# ── 4. 安装：复制 payload ──────────────────────────────────────────
Write-Step '安装技能目录'
if (-not (Test-Path $payload)) { throw "payload 缺失：$payload（请从解压后的完整目录运行本脚本）" }
New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
Copy-Item (Join-Path $payload '*') $skillDir -Recurse -Force
foreach ($f in @('SKILL.md', "scripts\qianfan_search.py", "mcp\server.mjs")) {
  if (-not (Test-Path (Join-Path $skillDir $f))) { throw "复制后缺少文件：$f" }
}
Write-Ok "已复制到 $skillDir"

$serverPath = Join-Path $skillDir 'mcp\server.mjs'
$configPath = Join-Path $skillDir 'config.json'

# ── 5. 安装：config.json ───────────────────────────────────────────
Write-Step '准备 config.json（API Key）'
if (Test-Path $configPath) {
  $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Key) {
    $cfg.api_key = $Key
    Write-Json -Path $configPath -Object $cfg
    Write-Ok '已更新已有 config.json 里的 api_key'
  } else {
    Write-Ok '已存在 config.json，保持不动（密钥沿用原值）'
  }
} else {
  $example = Join-Path $skillDir 'config.example.json'
  $cfg = Get-Content $example -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Key) { $cfg.api_key = $Key }
  else { $cfg.api_key = '' }
  Write-Json -Path $configPath -Object $cfg
  if ($Key) { Write-Ok '已用 -Key 生成 config.json' }
  else      { Write-Warn2 "已生成 config.json，但里面没有密钥 —— 请把千帆 API Key 填进：$configPath" }
}
if ($env:QIANFAN_API_KEY) { Write-Ok '检测到环境变量 QIANFAN_API_KEY（优先级高于 config.json）' }

# ── 6. 安装：给每个 profile 接线 ──────────────────────────────────
Write-Step '接线到 dsh-mcp-client（每个 profile 一段托管块）'
if (-not $node) {
  Write-Warn2 '没有 Node 路径，无法接线。请先确定 node.exe，再执行：'
  Write-Host "      powershell -ExecutionPolicy Bypass -File install.ps1 -NodePath '<node.exe 绝对路径>'" -ForegroundColor Yellow
  exit 1
}

$esc = { param($s) $s.Replace("'", "''") }
$block = @(
  $BEGIN,
  '# 百度千帆联网搜索 —— 本地 MCP 服务（stdio，零依赖）。',
  '# 独立进程，与内核版本解耦；dsh-mcp-client 把它的工具注册进 ctx.tools，',
  "# 模型看到的公开名为 mcp__${ServerName}__baidu_search。整块删除即可完全回退。",
  '- insert:',
  '    - id: mcp-qianfan',
  "      name: '@deepseek-ai/dsh-mcp-client'",
  '      config:',
  '        transport: stdio',
  "        serverName: $ServerName",
  "        command: '$(& $esc $node)'",
  '        args:',
  "          - '$(& $esc $serverPath)'",
  "        cwd: '$(& $esc $skillDir)'",
  '        toolCallTimeoutMs: 60000',
  $END
) -join [Environment]::NewLine

$patched = 0
foreach ($p in Get-ProfilePatches -Only $Profiles) {
  $text = [System.IO.File]::ReadAllText($p)
  $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $blockNative = ($block -replace "`r`n", $eol)
  $bak = "$p.bak-qianfan-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item $p $bak -Force

  if ($text -match [regex]::Escape($BEGIN)) {
    $pattern = "(?ms)^" + [regex]::Escape($BEGIN) + ".*?^" + [regex]::Escape($END) + "\r?\n?"
    # 用字符串替换（不引委托，兼容 Windows PowerShell 5.1）；替换串里的 $ 需转义
    $replacement = $blockNative.Replace('$', '$$')
    $new = [regex]::Replace($text, $pattern, $replacement)
    [System.IO.File]::WriteAllText($p, $new, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "已更新托管块：$p"
  } else {
    $sep = if ($text.EndsWith($eol)) { '' } else { $eol }
    [System.IO.File]::WriteAllText($p, $text + $sep + $eol + $blockNative + $eol, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "已追加托管块：$p"
  }
  Write-Host "         备份：$bak"
  $patched++
}
if ($patched -eq 0) { Write-Warn2 "没有找到任何 profile 的 cordis.patch.yml（$profilesDir）" }

# ── 7. 自检 ────────────────────────────────────────────────────────
Write-Step '自检'
if ($SkipVerify) {
  Write-Warn2 '已按 -SkipVerify 跳过'
} else {
  $verify = Join-Path $PSScriptRoot 'verify.mjs'
  if ((Test-Path $verify) -and $node) {
    & $node $verify --server $serverPath --node $node
    if ($LASTEXITCODE -ne 0) {
      Write-Warn2 '自检未全部通过 —— 接线已写入，但请先按上面提示排查（常见原因：Key 没填 / 网络不通）'
    } else {
      Write-Ok 'MCP 协议自检通过'
    }
  } else {
    Write-Warn2 "跳过自检（缺少 verify.mjs 或 node）"
  }
}

# ── 8. 收尾提示 ────────────────────────────────────────────────────
Write-Host "`n================ 安装完成 ================" -ForegroundColor Cyan
Write-Host "技能目录   : $skillDir"
Write-Host "配置文件   : $configPath"
Write-Host "接线 profile: $patched 个"
Write-Host "原生工具名 : mcp__${ServerName}__baidu_search" -ForegroundColor Green
Write-Host "`n下一步："
Write-Host "  1) 重启 DeepSeek Harness（接线在启动时读取）"
Write-Host "  2) 开一个新对话，让 agent 查个中文近况试试"
Write-Host "  3) 技能需新对话才会出现在 agent 的技能列表里"
Write-Host "`n回退：powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   （加 -RemoveSkill 连技能目录一起删）" -ForegroundColor DarkGray
if (-not $env:QIANFAN_API_KEY) {
  $cur = (Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).api_key
  if ([string]::IsNullOrWhiteSpace($cur)) {
    Write-Host "`n[!] 提醒：config.json 里还没有 API Key，搜索会报错。" -ForegroundColor Yellow
  }
}
