<#
.SYNOPSIS
  Installs (or removes) subagent-tiering into the user's global Claude Code config (~/.claude).
.EXAMPLE
  .\install.ps1
  .\install.ps1 -Uninstall
  .\install.ps1 -ClaudeDir D:\other\.claude
#>
param(
    [switch]$Uninstall,
    [string]$ClaudeDir = (Join-Path $HOME '.claude')
)

$ErrorActionPreference = 'Stop'
$RepoDir   = $PSScriptRoot
$Name      = 'subagent-tiering'
$StartMark = "<!-- $Name`:start -->"
$EndMark   = "<!-- $Name`:end -->"
# Previous name of this project (shares its markers with an unrelated project, so the
# legacy block is only removed when it holds our own heading).
$LegacyStart   = '<!-- claude-model-router:start -->'
$LegacyEnd     = '<!-- claude-model-router:end -->'
$LegacyHeading = 'Model & sub-agent routing (token economy)'
$HookTags  = @("$Name/guard.js", 'model-router/guard.js')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Agents shipped by earlier versions: removed only if they still look like our copies.
$Retired = @{
    'worker.md'    = 'description: Implementer for a well-defined'
    'reviewer.md'  = 'description: Independent code reviewer. Use after a non-trivial change'
    'architect.md' = 'description: Expensive deep thinker'
    'scout.md'     = 'description: Fast, cheap read-only researcher'
}
$ManagedTag = "managed by $Name"

function Write-Utf8File([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom) }
function Remove-Block([string]$Text, [string]$Start, [string]$End, [string]$MustContain) {
    $pattern = '(?s)\r?\n?' + [regex]::Escape($Start) + '(.*?)' + [regex]::Escape($End) + '\r?\n?'
    return [regex]::Replace($Text, $pattern, {
        param($m) if (-not $MustContain -or $m.Groups[1].Value.Contains($MustContain)) { "`n" } else { $m.Value }
    })
}
function Test-OurHook($entry) {
    foreach ($h in @($entry.hooks)) { foreach ($t in $HookTags) { if ($h.command -and $h.command.Contains($t)) { return $true } } }
    return $false
}
function Set-HookEvent($settings, [string]$EventName, $newEntry) {
    $list = @()
    if ($settings.hooks.PSObject.Properties.Name -contains $EventName) {
        $list = @($settings.hooks.$EventName | Where-Object { -not (Test-OurHook $_) })
    }
    if ($newEntry) { $list += $newEntry }
    if ($list.Count -gt 0) { $settings.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue $list -Force }
    else { $settings.hooks.PSObject.Properties.Remove($EventName) }
}

New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
$agentsDir    = Join-Path $ClaudeDir 'agents'
$toolDir      = Join-Path $ClaudeDir $Name
$legacyDir    = Join-Path $ClaudeDir 'model-router'
$claudeMd     = Join-Path $ClaudeDir 'CLAUDE.md'
$settingsPath = Join-Path $ClaudeDir 'settings.json'
$envVars      = Get-Content (Join-Path $RepoDir 'settings\env.json') -Raw | ConvertFrom-Json
$hasNode      = [bool](Get-Command node -ErrorAction SilentlyContinue)
$installHook  = (-not $Uninstall) -and $hasNode

# --- 1. Agents ---------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $agentsDir | Out-Null
foreach ($file in $Retired.Keys) {
    $target = Join-Path $agentsDir $file
    if ((Test-Path $target) -and ([System.IO.File]::ReadAllText($target).Contains($Retired[$file]))) {
        Remove-Item $target -Confirm:$false; Write-Host "  - retired agent $file removed"
    }
}
foreach ($agent in Get-ChildItem (Join-Path $RepoDir 'agents') -Filter *.md) {
    $target = Join-Path $agentsDir $agent.Name
    if ($Uninstall) {
        if ((Test-Path $target) -and ([System.IO.File]::ReadAllText($target).Contains($ManagedTag))) {
            Remove-Item $target -Confirm:$false; Write-Host "  - agent $($agent.Name) removed"
        }
        if ((Test-Path "$target.bak") -and -not (Test-Path $target)) {
            Move-Item "$target.bak" $target; Write-Host "  + your previous $($agent.Name) restored"
        }
    } else {
        if ((Test-Path $target) -and -not ([System.IO.File]::ReadAllText($target).Contains($ManagedTag))) {
            Copy-Item $target "$target.bak" -Force; Write-Host "  ! existing $($agent.Name) backed up to $($agent.Name).bak"
        }
        Copy-Item $agent.FullName $target -Force
        Write-Host "  + agent $($agent.Name)"
    }
}

# --- 2. Global CLAUDE.md (managed block between markers) ---------------------
$existing = ''
if (Test-Path $claudeMd) { $existing = [System.IO.File]::ReadAllText($claudeMd) }
$cleaned = Remove-Block $existing $StartMark $EndMark $null
$cleaned = (Remove-Block $cleaned $LegacyStart $LegacyEnd $LegacyHeading).TrimEnd()
if (-not $Uninstall) {
    $rules = [System.IO.File]::ReadAllText((Join-Path $RepoDir 'rules\CLAUDE.md')).TrimEnd()
    $block = "$StartMark`n$rules`n$EndMark"
    if ($cleaned) { $cleaned = "$cleaned`n`n$block" } else { $cleaned = $block }
}
if ($cleaned -or (Test-Path $claudeMd)) { Write-Utf8File $claudeMd ($cleaned + "`n") }
Write-Host ("  " + $(if ($Uninstall) { '- rules removed from' } else { '+ rules written to' }) + " $claudeMd")

# --- 3. Hook files (+ migration from the legacy folder) ----------------------
if ((Test-Path (Join-Path $legacyDir 'guard.js'))) {
    if (-not $Uninstall) {
        New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
        foreach ($f in 'dispatch.log', 'config.json') {
            $src = Join-Path $legacyDir $f; $dst = Join-Path $toolDir $f
            if ((Test-Path $src) -and -not (Test-Path $dst)) { Move-Item $src $dst }
        }
    }
    Remove-Item $legacyDir -Recurse -Force -Confirm:$false
    Write-Host "  - legacy folder $legacyDir migrated and removed"
}
if ($Uninstall) {
    if (Test-Path $toolDir) { Remove-Item $toolDir -Recurse -Force -Confirm:$false; Write-Host "  - $toolDir removed" }
} elseif ($installHook) {
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
    Copy-Item (Join-Path $RepoDir 'hooks\guard.js') (Join-Path $toolDir 'guard.js') -Force
    $cfg = Join-Path $toolDir 'config.json'
    if (-not (Test-Path $cfg)) { Copy-Item (Join-Path $RepoDir 'hooks\config.json') $cfg }
    Write-Host "  + hook copied to $toolDir (config.json kept if it already existed)"
} else {
    Write-Warning "Node.js not found: the hook is skipped (rules, agents and env vars are still installed)."
}

# --- 4. settings.json: env vars + hooks ----------------------------------------
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = New-Object PSObject
}

if (-not ($settings.PSObject.Properties.Name -contains 'env')) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue (New-Object PSObject)
}
foreach ($prop in $envVars.PSObject.Properties) {
    if ($Uninstall) { $settings.env.PSObject.Properties.Remove($prop.Name) }
    else { $settings.env | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force }
}
if (@($settings.env.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('env') }

# top-level keys (e.g. default model); on uninstall, removed only if still our value
$topKeys = Get-Content (Join-Path $RepoDir 'settings\settings.json') -Raw | ConvertFrom-Json
foreach ($prop in $topKeys.PSObject.Properties) {
    if ($Uninstall) {
        if ($settings.PSObject.Properties.Name -contains $prop.Name -and $settings.($prop.Name) -eq $prop.Value) {
            $settings.PSObject.Properties.Remove($prop.Name)
        }
    } else {
        $settings | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
}

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject)
}
$preEntry = $null; $stopEntry = $null
if ($installHook) {
    $cmd = 'node "' + ((Join-Path $toolDir 'guard.js') -replace '\\', '/') + '"'
    $preEntry  = [PSCustomObject]@{ matcher = 'Agent|Task'; hooks = @([PSCustomObject]@{ type = 'command'; command = $cmd; timeout = 10 }) }
    $stopEntry = [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = 'command'; command = $cmd; timeout = 15 }) }
}
Set-HookEvent $settings 'PreToolUse'   $preEntry
Set-HookEvent $settings 'SubagentStop' $stopEntry
if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }

Write-Utf8File $settingsPath (($settings | ConvertTo-Json -Depth 32) + "`n")
Write-Host ("  " + $(if ($Uninstall) { '- env vars and hooks removed from' } else { '+ env vars and hooks set in' }) + " $settingsPath (backup: settings.json.bak)")

Write-Host ''
Write-Host $(if ($Uninstall) { "$Name uninstalled." } else { "$Name installed. Restart Claude Code sessions to pick it up." })
