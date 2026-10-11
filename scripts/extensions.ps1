# Optional extensions: folders in extensions\ with an extension.yaml (title, description, needs, download_gb), a
# docker-compose.yml (the extension's service, plus a "download" service under the download profile), and setup.ps1,
# which defines Invoke-ExtSetup-<name>: the extension's own questions; it writes extensions\<name>\.env and returns
# $false when the extension cannot run here. Installed extensions are listed under extensions.enabled in config.yaml;
# the image server then offers their tools on its own MCP address. Dot-sourced by lib.ps1.

function Get-ExtAvailable {
    @(Get-ChildItem -LiteralPath (Join-Path $Root 'extensions') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'extension.yaml') } | ForEach-Object { $_.Name })
}
function Get-ExtManifest([string]$Name) { Read-TextFile "extensions\$Name\extension.yaml" }
function Get-ExtField([string]$Name, [string]$Key) {
    if ((Get-ExtManifest $Name) -match "(?m)^${Key}:[ \t]*([^#\r\n]*)") { $Matches[1].Trim().Trim('"', "'") } else { '' }
}
function Get-ExtDescription([string]$Name) {
    $m = ([regex]'(?ms)^description:[^\r\n]*\r?\n(.*?)(?=^[^ \t]|\z)').Match((Get-ExtManifest $Name))
    if ($m.Success) { (($m.Groups[1].Value -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ' } else { '' }
}
function Get-ExtEnabled {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'config.yaml'))) { return @() }
    $v = Get-YamlValue (Read-TextFile 'config.yaml') 'extensions' 'enabled'
    @(($v -replace '[\[\]"'' ]', '') -split ',' | Where-Object { $_ })
}
function Set-ExtEnabled([string[]]$Names) {
    $list = '[' + ((@($Names) | Where-Object { $_ }) -join ', ') + ']'
    Write-TextFile 'config.yaml' (Set-Yaml (Read-TextFile 'config.yaml') 'enabled' $list 'extensions')
}
function Invoke-ExtCompose([string]$Name, [string[]]$ArgList, [switch]$Console) {
    $a = @('compose', '-f', "extensions/$Name/docker-compose.yml") + $ArgList
    if ($Console) { return (Invoke-Console 'docker' $a) }
    (Invoke-Program 'docker' $a).Code
}
function Write-Wrapped([string]$Text, [string]$Indent = '    ') {
    $line = ''
    foreach ($w in ($Text -split ' ')) {
        if (($line.Length + $w.Length + 1) -gt 106) { Write-Host "$Indent$line"; $line = $w } else { $line = ($line + ' ' + $w).Trim() }
    }
    if ($line) { Write-Host "$Indent$line" }
}

# After the image settings are saved, ask about each extension. $m: Get-Machine.
function Invoke-ExtSetup($m) {
    $keep = @()
    $enabled = Get-ExtEnabled
    foreach ($name in Get-ExtAvailable) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root "extensions\$name\setup.ps1"))) { continue }
        Write-Host ''
        Write-Host "Optional extension: $(Get-ExtField $name 'title')"
        Write-Wrapped (Get-ExtDescription $name)
        Write-Host ''
        $was = $enabled -contains $name
        if ((Get-ExtField $name 'needs') -eq 'nvidia' -and $m.GpuCount -eq 0) {
            Write-Host '    It needs an NVIDIA GPU. None was found, so it is not offered.'
            if ($was) { Remove-Ext $name }
            continue
        }
        if (Read-YesNo 'Install this extension?' $was) {
            . (Join-Path $Root "extensions\$name\setup.ps1")
            if (& "Invoke-ExtSetup-$name" $m) { $keep += $name } elseif ($was) { Remove-Ext $name }
        } elseif ($was) {
            Remove-Ext $name
        }
    }
    Set-ExtEnabled $keep
}

# Stop it and take it out of config.yaml; its downloaded files are deleted only when asked.
function Remove-Ext([string]$Name) {
    Write-Host "==> Removing the $Name extension."
    Invoke-ExtCompose $Name @('down') | Out-Null
    Invoke-Program 'docker' @('image', 'rm', "imagegen-$($Name):latest") | Out-Null  # its Docker image (several GB)
    Set-ExtEnabled @(Get-ExtEnabled | Where-Object { $_ -ne $Name })
    $models = Join-Path $Root "extensions\$Name\models"
    if (Test-Path -LiteralPath $models) {
        $gb = Get-ExtField $Name 'download_gb'
        if (Read-YesNo "Also delete its downloaded files (about $gb GB)?" $false) { Remove-Item -LiteralPath $models -Recurse -Force }
    }
}

# Build (once, or after an update), download (once) and start every installed extension.
function Start-Exts {
    foreach ($name in Get-ExtEnabled) {
        $dir = Join-Path $Root "extensions\$name"
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'docker-compose.yml'))) {
            Write-Host "Extension $name is listed in config.yaml, but extensions\$name is missing." -ForegroundColor Red; continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $dir '.env'))) {
            Write-Host "Extension $name has no settings yet: run setup.cmd." -ForegroundColor Red; continue
        }
        Write-Host ''
        Write-Host "==> Extension: $(Get-ExtField $name 'title')"
        $mark = Join-Path $dir '.build-needed'
        $image = (Invoke-Program 'docker' @('image', 'inspect', "imagegen-${name}:latest")).Code -eq 0
        if ((Test-Path -LiteralPath $mark) -or -not $image) {
            Write-Host '    Building its image (the first time takes several minutes)...'
            if ((Invoke-ExtCompose $name @('build') -Console) -ne 0) { Write-Host "The $name extension could not be built." -ForegroundColor Red; continue }
            Remove-Item -LiteralPath $mark -ErrorAction SilentlyContinue
        }
        $ready = Join-Path $dir 'models\.ready'
        if (-not (Test-Path -LiteralPath $ready)) {
            Write-Host "    Downloading its models once (about $(Get-ExtField $name 'download_gb') GB) and checking them..."
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'models') | Out-Null
            if ((Invoke-ExtCompose $name @('--profile', 'download', 'run', '--rm', 'download') -Console) -ne 0) {
                Write-Host "The $name extension's download did not finish. Run start.cmd again to continue it." -ForegroundColor Red; continue
            }
            Set-Content -LiteralPath $ready -Value 'downloaded and checked' -Encoding ascii
        }
        if ((Invoke-ExtCompose $name @('up', '-d')) -ne 0) { Write-Host "The $name extension could not be started." -ForegroundColor Red; continue }
        $state = ''
        foreach ($i in 1..40) {
            $r = Invoke-Program 'docker' @('inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', "imagegen-$name")
            $state = "$(Get-FirstLine $r.Out)".Trim()
            if ($state -in 'healthy', 'running') { break }
            Start-Sleep -Seconds 3
        }
        if ($state -in 'healthy', 'running') { Write-Host "    Ready. Its tools are offered on the server's MCP address within a few seconds." }
        else { Write-Host "    It did not start ($state). See: docker logs imagegen-$name" -ForegroundColor Red }
    }
}

# Stop every extension that has a container (installed or not).
function Stop-Exts {
    foreach ($name in Get-ExtAvailable) {
        if ((Invoke-Program 'docker' @('inspect', "imagegen-$name")).Code -eq 0) { Invoke-ExtCompose $name @('down') | Out-Null }
    }
}

# After an update: rebuild the extensions whose files changed between the two commits.
function Set-ExtChanged([string]$Old) {
    foreach ($name in Get-ExtAvailable) {
        $d = Invoke-Git @('diff', '--name-only', $Old, 'HEAD', '--', "extensions/$name")
        if (@($d.Out | Where-Object { "$_".Trim() }).Count -gt 0) {
            Set-Content -LiteralPath (Join-Path $Root "extensions\$name\.build-needed") -Value 'an update changed it' -Encoding ascii
        }
    }
}
