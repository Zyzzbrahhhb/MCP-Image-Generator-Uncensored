# Image Gen MCP: the shared code of scripts\imagegen.ps1 (setup.cmd, start.cmd, update.cmd and stop.cmd run it).
#   step 1  Test-Docker     Docker is installed and running
#   2-3b    Invoke-Setup    where the server runs and which model it uses, saved in config.yaml
#   step 4  Start-Server    build the image, start the server, download the model, wait until it is loaded
#           Invoke-Update   install the latest version with git
# Uses $Root and $Launcher from imagegen.ps1. Keep this file ASCII only (PowerShell 5.1).
# Keep the texts and the model choices the same as in scripts/lib.sh (tests/test_start_scripts.py checks them).

# The model choices, the same rows as in scripts/lib.sh:
# name|variant|quant|text encoder quant|download GB|seconds per 1024x1024 image on a 12 GB GPU|needs
$Presets = @(
    'Best quality|uncensored|Q4_K_M|Q8_0|15.5|90|GPU 12 GB+, 20 GB memory'
    'Standard|uncensored|Q4_K_M|Q4_K_M|11.8|90|GPU 12 GB+, 16 GB memory'
    'Turbo|turbo|Q4_K_M|Q4_K_M|11.4|12|GPU 8 GB+ or CPU, 16 GB memory'
) | ForEach-Object {
    $f = $_ -split '\|'
    [pscustomobject]@{ Name = $f[0]; Variant = $f[1]; Quant = $f[2]; TE = $f[3]; GB = $f[4]; Sec = $f[5]; Needs = $f[6] }
}
$TurboChoice = 3
$ProjectUrl = 'https://github.com/hypersniper05/MCP-Image-Generator-Uncensored'
# Set by the update when the server code changed: the next start builds the image again.
$BuildMark = '.build-needed'

# True when a person runs this in a terminal, so questions can be asked.
function Test-Interactive {
    -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or
          ([Environment]::GetCommandLineArgs() -match '^-noni'))
}

# --- input --------------------------------------------------------------------------------------------------------
function Read-Answer([string]$Prompt, [string]$Default) {
    $a = "$(Read-Host "$Prompt [$Default]")".Trim()
    if ($a) { $a } else { $Default }
}
function Read-YesNo([string]$Prompt, [bool]$Default) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = "$(Read-Host "$Prompt $hint")".Trim()
    if (-not $a) { return $Default }
    return ($a -match '^[yY]')
}
function Read-Choice([int]$Max, [int]$Default) {
    while ($true) {
        $a = Read-Answer 'Type a number and press Enter' "$Default"
        if ($a -match '^\d{1,2}$' -and [int]$a -ge 1 -and [int]$a -le $Max) { return [int]$a }
        Write-Host "Please type a number from 1 to $Max."
    }
}

# --- files and programs ---------------------------------------------------------------------------------------------
# [IO.File] keeps UTF-8 intact (Get-Content/Set-Content do not in PowerShell 5.1). Full paths: .NET does not follow
# Set-Location.
function Read-TextFile([string]$Name) { [IO.File]::ReadAllText((Join-Path $Root $Name)) }
function Write-TextFile([string]$Name, [string]$Text) {
    [IO.File]::WriteAllText((Join-Path $Root $Name), $Text, (New-Object Text.UTF8Encoding $false))
}
# Run a program and collect its output. Its error output is collected too (never shown, never a script error).
function Invoke-Program([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out = New-Object Collections.Generic.List[string]
    $err = New-Object Collections.Generic.List[string]
    & $Exe @ArgList 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $err.Add("$_") } else { $out.Add("$_") }
    }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out); Err = @($err) }
}
function Invoke-Git([string[]]$ArgList) { Invoke-Program 'git' (@('--no-pager', '-C', $Root) + $ArgList) }
function Get-FirstLine($Lines) { @($Lines | Where-Object { "$_".Trim() })[0] }

# --- config.yaml ----------------------------------------------------------------------------------------------------
# Set "key: value" in YAML text, keeping the rest of the line (its comment). With a section, only that top-level
# section is searched (vae: is both in model: and in gpu:).
function Set-Yaml([string]$Text, [string]$Key, [string]$Value, [string]$Section = '') {
    $val = $Value.Replace('$', '$$')
    $item = '(\{[^}\r\n]*\}|\[[^\]\r\n]*\]|[^\s#]*)'
    if (-not $Section) {
        $rx = [regex]"(?m)^($Key[ \t]*:[ \t]*)$item"
        if ($rx.IsMatch($Text)) { return $rx.Replace($Text, "`${1}$val", 1) }
        return "${Key}: $Value`n$Text"
    }
    # The section: from its "name:" line to the next top-level key.
    $m = ([regex]"(?ms)^$Section[ \t]*:[^\r\n]*\r?\n(.*?)(?=^[A-Za-z_]|\z)").Match($Text)
    if ($m.Success) {
        $body = $m.Groups[1]
        $rx = [regex]"(?m)^([ \t]+$Key[ \t]*:[ \t]*)$item"
        if ($rx.IsMatch($body.Value)) {
            return $Text.Substring(0, $body.Index) + $rx.Replace($body.Value, "`${1}$val", 1) +
                $Text.Substring($body.Index + $body.Length)
        }
    }
    $sec = [regex]"(?m)^$Section[ \t]*:[ \t]*(#[^\r\n]*)?(?=\r?$)"
    if ($sec.IsMatch($Text)) { return $sec.Replace($Text, "`$0`n  ${Key}: $val", 1) }
    if ($Text -match "(?m)^$Section[ \t]*:") { throw "config.yaml: change $Section.$Key by hand (this layout is not supported)" }
    return $Text.TrimEnd() + "`n${Section}:`n  ${Key}: $Value`n"
}
# KEY's value inside the top-level SECTION of YAML text, without its comment and quotes ('' when it is not there).
function Get-YamlValue([string]$Text, [string]$Section, [string]$Key) {
    $m = ([regex]"(?ms)^$Section[ \t]*:[^\r\n]*\r?\n(.*?)(?=^[A-Za-z_]|\z)").Match($Text)
    if ($m.Success -and $m.Groups[1].Value -match "(?m)^[ \t]+$Key[ \t]*:[ \t]*([^#\r\n]*)") {
        $Matches[1].Trim().Trim('"', "'")
    } else { '' }
}
function Get-ModelText([string]$Text, $Preset) {
    $Text = Set-Yaml $Text 'variant' $Preset.Variant 'model'
    $Text = Set-Yaml $Text 'quant' $Preset.Quant 'model'
    Set-Yaml $Text 'text_encoder_quant' $Preset.TE 'model'
}
function Get-PresetText($Preset) { "$($Preset.Name) ($($Preset.Variant) $($Preset.Quant), text encoder $($Preset.TE))" }

# The model in config.yaml: Index = its number in the list (0 = none of them, or no config.yaml),
# Text = "Standard (uncensored Q4_K_M, text encoder Q4_K_M)" or "custom (...)".
function Get-CurrentModel {
    if (-not (Test-Path (Join-Path $Root 'config.yaml'))) { return [pscustomobject]@{ Text = ''; Index = 0 } }
    $y = Read-TextFile 'config.yaml'
    $v = (Get-YamlValue $y 'model' 'variant').ToLower(); if (-not $v) { $v = 'uncensored' }
    $q = (Get-YamlValue $y 'model' 'quant').ToUpper() -replace '^AD-', ''; if (-not $q) { $q = 'Q4_K_M' }
    $alias = @{ Q4 = 'Q4_K_M'; Q4_K = 'Q4_K_M'; Q5 = 'Q5_K_M'; Q5_K = 'Q5_K_M'; Q6 = 'Q6_K'; Q8 = 'Q8_0' }
    if ($alias.ContainsKey($q)) { $q = $alias[$q] }
    $t = (Get-YamlValue $y 'model' 'text_encoder_quant').ToUpper(); if (-not $t) { $t = 'Q4_K_M' }
    $d = "$v $q, text encoder $t"
    for ($i = 0; $i -lt $Presets.Count; $i++) {
        $p = $Presets[$i]
        if ($p.Variant -eq $v -and $p.Quant -eq $q -and $p.TE -eq $t) {
            return [pscustomobject]@{ Text = "$($p.Name) ($d)"; Index = $i + 1 }
        }
    }
    [pscustomobject]@{ Text = "custom ($d)"; Index = 0 }
}
# The saved device and GPU places: Device, Img ("0" or "0 2"), TE and Dec ("2" or "cpu"). Empty without config.yaml.
function Read-Current {
    $c = @{ Device = ''; Img = ''; TE = ''; Dec = '' }
    if (-not (Test-Path (Join-Path $Root 'config.yaml'))) { return $c }
    $y = Read-TextFile 'config.yaml'
    if ($y -match '(?m)^device[ \t]*:[ \t]*"?([A-Za-z]+)') { $c.Device = $Matches[1].ToLower() }
    $c.Img = @((Get-YamlValue $y 'gpu' 'diffusion') -replace '[\[\]]', '' -split '[,\s]+' | Where-Object { $_ }) -join ' '
    if (-not $c.Img) { $c.Img = '0' }
    $first = ($c.Img -split ' ')[0]
    $c.TE = Get-YamlValue $y 'gpu' 'text_encoder'; if (-not $c.TE) { $c.TE = $first }
    $c.Dec = Get-YamlValue $y 'gpu' 'vae'; if (-not $c.Dec) { $c.Dec = $first }
    $c
}

# --- this computer --------------------------------------------------------------------------------------------------
# Gpus: every NVIDIA GPU (Index, Name, GB). VramGB: the first GPU's memory. DockerGB: memory Docker can use
# (0 = unknown).
function Get-Machine {
    $m = @{ Mac = [bool]$IsMacOS; Gpus = @(); GpuCount = 0; VramGB = 0; DockerGB = 0 }
    $r = Invoke-Program 'docker' @('info', '--format', '{{.MemTotal}}')
    $mem = @($r.Out | Where-Object { $_ -match '^\s*\d+\s*$' })[0]
    if ($r.Code -eq 0 -and $mem) { $m.DockerGB = [int][math]::Round([double]$mem / 1GB) }
    if (-not $m.Mac -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        $r = Invoke-Program 'nvidia-smi' @('--query-gpu=index,name,memory.total', '--format=csv,noheader,nounits')
        if ($r.Code -eq 0) {
            $m.Gpus = @(foreach ($line in $r.Out) {
                $f = $line -split ','
                if ($f.Count -ge 3 -and $f[0].Trim() -match '^\d+$' -and $f[-1].Trim() -match '^\d+$') {
                    [pscustomobject]@{ Index = [int]$f[0].Trim(); Name = ($f[1..($f.Count - 2)] -join ',').Trim()
                                       GB = [int][math]::Floor(([int]$f[-1].Trim() + 512) / 1024) }
                }
            })
        }
    }
    $m.GpuCount = $m.Gpus.Count
    if ($m.GpuCount -gt 0) { $m.VramGB = $m.Gpus[0].GB }
    $m
}
function Get-Gpu($m, [int]$Index) { @($m.Gpus | Where-Object { $_.Index -eq $Index })[0] }
function Get-CpuName {
    try { $n = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { $n = '' }
    if ($n) { $n.Trim() } else { 'your CPU' }
}
function Get-GpuLabel($m, [int]$Index) { $g = Get-Gpu $m $Index; "GPU $($g.Index) ($($g.Name), $($g.GB) GB)" }
function Get-PlaceLabel($m, [string]$Place) {
    if ($Place -eq 'cpu') { return "CPU ($(Get-CpuName))" }
    (@($Place -split ' ') | ForEach-Object { Get-GpuLabel $m ([int]$_) }) -join ' + '
}
# "CPU", "GPU 2" or "GPU 0 + GPU 2".
function Get-PlaceShort([string]$Place) { if ($Place -eq 'cpu') { 'CPU' } else { 'GPU ' + (($Place -split ' ') -join ' + GPU ') } }
# Where the server runs, from config.yaml: "CPU", "GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)" or a split.
function Get-DeviceText($m) {
    $c = Read-Current
    if ($c.Device -eq 'cpu') { return 'CPU' }
    if ($c.Img -eq $c.TE -and $c.TE -eq $c.Dec) {
        if ($c.Img -match '^\d+$' -and (Get-Gpu $m ([int]$c.Img))) { return Get-GpuLabel $m ([int]$c.Img) }
        return "GPU $($c.Img)"
    }
    "image model on $(Get-PlaceShort $c.Img), text encoder on $(Get-PlaceShort $c.TE), image decoder on $(Get-PlaceShort $c.Dec)"
}
function Show-Settings($m) {
    Write-Host "    Model:  $((Get-CurrentModel).Text)"
    Write-Host "    Device: $(Get-DeviceText $m)"
}

# --- step 1: Docker -------------------------------------------------------------------------------------------------
# When Docker is missing or not running, say what to do and stop (nothing is started for the person).
function Test-Docker {
    Write-Host '==> Checking Docker...'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host 'Docker is not installed. The image server needs Docker Desktop.' -ForegroundColor Red
        Write-Host '  1. Download and install it: https://www.docker.com/products/docker-desktop/'
        Write-Host '  2. Open Docker Desktop and wait until it says Engine running.'
        Write-Host "  3. Run $Launcher again."
        exit 1
    }
    if ((Invoke-Program 'docker' @('info')).Code -ne 0) {
        Write-Host 'Docker is installed but not running. Start Docker Desktop, wait until it says Engine running,' -ForegroundColor Red
        Write-Host "then run $Launcher again." -ForegroundColor Red
        exit 1
    }
    Write-Host '    Docker is running.'
}

# --- step 2: which GPU ----------------------------------------------------------------------------------------------
# Show the GPUs; with more than one, ask which one to use. Returns @{ List = GPU numbers; Split = $true/$false }.
# The last choice, split, is set up after the model is chosen (Invoke-Split), because it depends on the model's size.
function Select-Gpu($m, [string]$Default) {
    if ($m.GpuCount -eq 1) {
        Write-Host "    GPU: $($m.Gpus[0].Name), $($m.Gpus[0].GB) GB"
        return @{ List = @($m.Gpus[0].Index); Split = $false }
    }
    Write-Host '    GPUs found:'
    foreach ($g in $m.Gpus) { Write-Host "      $($g.Index)) $($g.Name), $($g.GB) GB" }
    Write-Host "      $($m.GpuCount)) Split the model across several GPUs"
    Write-Host ''
    Write-Host 'Which GPU should the image server use?'
    while ($true) {
        $a = Read-Answer 'Type a number and press Enter' $Default
        if ($a -match '^\d{1,2}$') {
            if ([int]$a -eq $m.GpuCount) {
                Write-Host '    The split is set up after you choose the model.'
                return @{ List = @($m.Gpus | ForEach-Object { $_.Index }); Split = $true }
            }
            if (Get-Gpu $m ([int]$a)) { return @{ List = @([int]$a); Split = $false } }
        }
        Write-Host "Please type a number from 0 to $($m.GpuCount)."
    }
}
# Say why only the CPU is possible and ask whether to go on. No ends the setup.
function Confirm-Cpu([string]$Reason, $m) {
    Write-Host ''
    Write-Host $Reason -ForegroundColor Yellow
    if (Read-YesNo 'Continue on the CPU (several minutes per image)?' $true) { return }
    if ($m.Mac) { Write-Host "Nothing was changed. Run $Launcher again when you want to set it up." }
    else { Write-Host "Nothing was changed. If you have an NVIDIA GPU, install its driver, then run $Launcher again." }
    exit 0
}

# --- step 3: the model ----------------------------------------------------------------------------------------------
# Device and recommended choice for the GPU memory in VramGB (the total when the model is split).
function Get-Recommendation($m) {
    if ($m.Mac -or $m.VramGB -lt 8) { return @{ Device = 'cpu'; Preset = $TurboChoice } }
    $preset = if ($m.VramGB -lt 12) { $TurboChoice } elseif ($m.DockerGB -ge 20) { 1 } else { 2 }
    @{ Device = 'gpu'; Preset = $preset }
}
function Show-Presets([int]$Recommended, [bool]$Cpu, [int]$Current) {
    Write-Host '    Choice          Download  Time per image  Needs'
    for ($i = 0; $i -lt $Presets.Count; $i++) {
        $p = $Presets[$i]
        $time = if ($Cpu) { 'minutes' } else { "~$($p.Sec) s" }
        $needs = if ($Cpu) { $p.Needs -replace '^.*, ', '' } else { $p.Needs }
        $mark = ''
        if ($i + 1 -eq $Current -and $i + 1 -eq $Recommended) { $mark = '  <- current, recommended' }
        elseif ($i + 1 -eq $Current) { $mark = '  <- current' }
        elseif ($i + 1 -eq $Recommended) { $mark = '  <- recommended' }
        $line = ' {0}) {1,-15} {2,5} GB  {3,-14}  {4}' -f ($i + 1), $p.Name, $p.GB, $time, $needs
        if ($mark) { Write-Host "$line$mark" -ForegroundColor Green } else { Write-Host $line }
    }
    Write-Host ''
    if ($Cpu) { Write-Host ' On the CPU every image takes several minutes. 1 and 2 use the uncensored model.' }
    else { Write-Host ' Times are for one 1024x1024 image on a 12 GB GPU. 1 and 2 use the uncensored model.' }
    Write-Host " $TurboChoice uses the official Turbo model (not uncensored): much faster, weaker at small text."
}
# Best quality needs about 18 GB of memory: ask before using it when Docker has less than 20 GB.
function Confirm-Choice([int]$Choice, $m) {
    if ($Choice -ne 1 -or $m.DockerGB -le 0 -or $m.DockerGB -ge 20) { return $true }
    Write-Host "Best quality needs 20 GB of memory for Docker, but Docker can use only $($m.DockerGB) GB." -ForegroundColor Yellow
    Read-YesNo 'Use it anyway?' $false
}

# --- step 3b: where each part of the model runs (only after "Split") ------------------------------------------------
# Sizes in GB of the parts of a model choice (the files the server loads), as text so they print like lib.sh.
function Get-ImageGB($Preset) { if ($Preset.Variant -eq 'turbo') { '4.2' } else { '4.6' } }
function Get-EncoderGB($Preset) { switch ($Preset.TE) { 'Q8_0' { '8.7' } 'F16' { '16.4' } default { '5.0' } } }
$DecoderGB = '0.7'
# The menu number for a saved place (the first GPU when it is not valid here).
function Get-PartDefault($m, [string]$Place, [switch]$Multi) {
    if ($Place -match ' ') { if ($Multi) { return "$($m.GpuCount)" } }
    elseif ($Place -eq 'cpu') { if (-not $Multi) { return "$($m.GpuCount)" } }
    elseif ($Place -match '^\d+$' -and (Get-Gpu $m ([int]$Place))) { return $Place }
    "$($m.Gpus[0].Index)"
}
# Ask where one part runs. Returns 'cpu', one GPU number, or several separated by spaces (only with -Multi).
function Read-Place($m, [string]$Name, [string]$GB, [string]$Default, [string]$Saved, [switch]$Multi) {
    $extra = $m.GpuCount
    Write-Host ''
    Write-Host "$Name ($GB GB): where should it run?"
    foreach ($g in $m.Gpus) { Write-Host "  $($g.Index)) GPU $($g.Index): $($g.Name), $($g.GB) GB" }
    if ($Multi) { Write-Host "  $extra) Several GPUs (split it)" } else { Write-Host "  $extra) CPU: $(Get-CpuName)" }
    while ($true) {
        $a = Read-Answer 'Type a number and press Enter' $Default
        if ($a -match '^\d{1,2}$') {
            if (Get-Gpu $m ([int]$a)) { return "$([int]$a)" }
            if ([int]$a -eq $extra -and -not $Multi) { return 'cpu' }
            if ([int]$a -eq $extra -and $Multi) { return (Read-GpuList $m $Saved) }
        }
        Write-Host "Please type a number from 0 to $extra."
    }
}
# Two or more GPUs for the image model (the saved ones are the default).
function Read-GpuList($m, [string]$Saved) {
    $all = ($m.Gpus | ForEach-Object { $_.Index }) -join ','
    $default = if ($Saved -match ' ') { $Saved -replace ' ', ',' } else { $all }
    while ($true) {
        $a = Read-Answer 'Which GPUs? Type their numbers separated by commas' $default
        $parts = @($a -split '[,\s]+' | Where-Object { $_ })
        $ok = $parts.Count -ge 2 -and @($parts | Where-Object { $_ -notmatch '^\d{1,2}$' -or -not (Get-Gpu $m ([int]$_)) }).Count -eq 0 -and
              @($parts | Select-Object -Unique).Count -eq $parts.Count
        if ($ok) { return (@($parts | ForEach-Object { [int]$_ }) -join ' ') }
        $default = $all
        Write-Host "Please type two or more different GPU numbers from the list, for example $all."
    }
}
# Place the image model, the text encoder and the image decoder one by one, then show all three with a warning for
# any GPU that may run out of memory, and confirm or start over. Returns @{ Img; TE; Dec }.
function Invoke-Split($m, $Preset, $Cur) {
    $ig = Get-ImageGB $Preset; $eg = Get-EncoderGB $Preset
    Write-Host ''
    Write-Host "Split $($Preset.Name): choose where each part of the model runs."
    while ($true) {
        $img = Read-Place $m 'Image model' $ig (Get-PartDefault $m $Cur.Img -Multi) $Cur.Img -Multi
        $te = Read-Place $m 'Text encoder' $eg (Get-PartDefault $m $Cur.TE) ''
        $dec = Read-Place $m 'Image decoder' $DecoderGB (Get-PartDefault $m $Cur.Dec) ''
        Write-Host ''
        Write-Host 'Your split:'
        Write-Host ('    {0,-24} {1}' -f "Image model ($ig GB):", (Get-PlaceLabel $m $img))
        Write-Host ('    {0,-24} {1}' -f "Text encoder ($eg GB):", (Get-PlaceLabel $m $te))
        Write-Host ('    {0,-24} {1}' -f "Image decoder ($DecoderGB GB):", (Get-PlaceLabel $m $dec))
        # Memory each GPU needs: the files plus working memory (image model +3 GB, split evenly; decoder +2.5 GB).
        # On a GPU under 20 GB the server keeps the text encoder's weights in RAM, so it needs about 1.5 GB there.
        $imgs = @($img -split ' ')
        $warn = @(foreach ($g in $m.Gpus) {
            $need = 0.0; $id = "$($g.Index)"
            if ($imgs -contains $id) { $need += ([double]$ig + 3) / $imgs.Count }
            if ($te -eq $id) { $need += $(if ($g.GB -lt 20) { 1.5 } else { [double]$eg + 2.2 }) }
            if ($dec -eq $id) { $need += 0.7 + 2.5 }
            if ($need -gt 0 -and $need -gt $g.GB - 2) {
                '    GPU {0} ({1}, {2} GB) may run out of memory: its parts need about {3:N0} GB.' -f $g.Index, $g.Name, $g.GB, $need
            }
        })
        if ($warn.Count -gt 0) {
            Write-Host ''
            $warn | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
            Write-Host '    The server then works more slowly (it moves parts to RAM) or stops with an out-of-memory error.' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  1) Confirm'
        Write-Host '  2) Start over'
        if ((Read-Choice 2 1) -eq 1) { return @{ Img = $img; TE = $te; Dec = $dec } }
    }
}

# --- saving the answers ---------------------------------------------------------------------------------------------
# GPU settings in config.yaml text: the GPU places, a memory limit for each GPU under 20 GB, and the text encoder's
# weights in RAM when it runs on such a GPU. Returns @{ Text; Note }.
function Set-GpuConfig([string]$Text, $m, [string]$Img, [string]$TE, [string]$Dec) {
    $imgs = @($Img -split ' ')
    $used = @(@($imgs + $TE + $Dec) | Where-Object { $_ -ne 'cpu' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $caps = @(); $limits = @()
    foreach ($i in $used) {
        $gb = (Get-Gpu $m $i).GB
        if ($gb -lt 20) { $caps += "${i}: $($gb - 2)"; $limits += "GPU $i limited to $($gb - 2) GB" }
    }
    $offload = 'auto'
    if ($TE -ne 'cpu' -and (Get-Gpu $m ([int]$TE)).GB -lt 20) { $offload = '{text_encoder: cpu}' }
    $cache = if ($caps.Count -gt 0) { 'q8_0' } else { 'auto' }
    $Text = Set-Yaml $Text 'diffusion' "[$($imgs -join ', ')]" 'gpu'
    $Text = Set-Yaml $Text 'text_encoder' $TE 'gpu'
    $Text = Set-Yaml $Text 'vae' $Dec 'gpu'
    $Text = Set-Yaml $Text 'max_vram_gb' "{$($caps -join ', ')}" 'gpu'
    $Text = Set-Yaml $Text 'offload' $offload 'gpu'
    $Text = Set-Yaml $Text 'prefix_cache_type' $cache 'generation'
    if ($Img -eq $TE -and $Img -eq $Dec) {
        $i = [int]$Img; $gb = (Get-Gpu $m $i).GB
        $note = if ($gb -lt 20) { "GPU $i (limited to $($gb - 2) GB); text encoder weights in RAM" } else { "GPU $i" }
    } else {
        $note = "image model on $(Get-PlaceShort $Img), text encoder on $(Get-PlaceShort $TE), image decoder on $(Get-PlaceShort $Dec)"
        if ($limits.Count -gt 0) { $note += " ($($limits -join ', '))" }
    }
    @{ Text = $Text; Note = $note }
}

# --- steps 2 to 3b: the setup ---------------------------------------------------------------------------------------
# Asks where the server runs and which model it uses and saves the answers in config.yaml. When config.yaml exists,
# its settings are the defaults, so Enter keeps them.
function Invoke-Setup {
    if (-not (Test-Interactive)) {
        Write-Host 'The setup asks questions, so run setup.cmd in a terminal.' -ForegroundColor Red
        exit 1
    }
    $m = Get-Machine
    $cur = Read-Current
    $model = Get-CurrentModel
    $haveConfig = Test-Path (Join-Path $Root 'config.yaml')
    Write-Host ''
    if ($haveConfig) {
        Write-Host '==> Setup. Your current settings are the defaults: press Enter to keep them.'
        Show-Settings $m
    } else {
        Write-Host '==> First-time setup'
    }
    Write-Host ''
    # Step 2: where the server runs.
    if ($m.DockerGB -gt 0) { Write-Host "    Memory Docker can use: $($m.DockerGB) GB" }
    $sel = $null
    if ($m.Mac) {
        Confirm-Cpu "This is a Mac. Docker on macOS cannot use the Mac's GPU, so the server runs on the CPU." $m
    } elseif ($m.GpuCount -eq 0) {
        Confirm-Cpu 'No NVIDIA GPU was found, so the server can only run on the CPU.' $m
    } else {
        $default = "$($m.Gpus[0].Index)"
        if ($cur.Device -eq 'gpu') {
            if ($cur.Img -ne $cur.TE -or $cur.TE -ne $cur.Dec) { $default = "$($m.GpuCount)" }
            elseif ($cur.Img -match '^\d+$' -and (Get-Gpu $m ([int]$cur.Img))) { $default = $cur.Img }
        }
        $sel = Select-Gpu $m $default
        $m.VramGB = (@($sel.List | ForEach-Object { (Get-Gpu $m $_).GB }) | Measure-Object -Sum).Sum
        if ($m.VramGB -lt 8) {
            Confirm-Cpu "That GPU has only $($m.VramGB) GB of memory (8 GB or more is needed), so the server can only run on the CPU." $m
            $sel = $null
        } elseif ($m.VramGB -lt 12) {
            Write-Host ''
            Write-Host "Note: GPUs with less than 12 GB have not been tested. Choice $TurboChoice is the most likely to fit." -ForegroundColor Yellow
        }
    }
    if ($m.DockerGB -gt 0 -and $m.DockerGB -lt 16) {
        Write-Host ''
        Write-Host "Warning: Docker can use only $($m.DockerGB) GB of memory, and the server needs about 16 GB. It may stop" -ForegroundColor Yellow
        Write-Host 'with an out-of-memory error. To give Docker more memory:' -ForegroundColor Yellow
        if ($m.Mac) { Write-Host 'Docker Desktop > Settings > Resources > Memory.' -ForegroundColor Yellow }
        else { Write-Host "see 'CPU mode or the Q8_0 text encoder is very slow or crashes on Windows' in README.md." -ForegroundColor Yellow }
    }
    $r = Get-Recommendation $m
    if (-not $sel) { $r.Device = 'cpu'; $r.Preset = $TurboChoice }

    # Step 3: the model.
    Write-Host ''
    Write-Host 'Which model do you want to use?'
    Write-Host ''
    Show-Presets $r.Preset ($r.Device -eq 'cpu') $model.Index
    $default = if ($model.Index -gt 0) { $model.Index } else { $r.Preset }
    do { $n = Read-Choice $Presets.Count $default } until (Confirm-Choice $n $m)
    $p = $Presets[$n - 1]

    # Step 3b: the split, now that the model is known. A split that puts every part on one GPU is that GPU.
    $place = $null
    if ($sel -and $sel.Split) { $place = Invoke-Split $m $p $cur }
    elseif ($sel) { $i = "$($sel.List[0])"; $place = @{ Img = $i; TE = $i; Dec = $i } }

    # Build the whole file in memory and write it last: Ctrl+C before this point leaves config.yaml as it was.
    # Other settings in config.yaml are kept.
    $source = if ($haveConfig) { 'config.yaml' } else { 'config.example.yaml' }
    $t = Set-Yaml (Read-TextFile $source) 'device' $r.Device
    $note = ''
    if ($r.Device -eq 'gpu' -and $place) {
        $g = Set-GpuConfig $t $m $place.Img $place.TE $place.Dec
        $t = $g.Text; $note = $g.Note
    }
    Write-TextFile 'config.yaml' (Get-ModelText $t $p)
    Write-Host ''
    Write-Host "==> Saved in config.yaml: $(Get-PresetText $p)"
    if ($note) { Write-Host "    and the GPU settings: $note." }
    elseif ($r.Device -eq 'cpu') { Write-Host '    and device: cpu (the server runs on the CPU).' }
}

# --- step 4: build, start, download, load ---------------------------------------------------------------------------
# Profile, Port, ImageRepo and Image from config.yaml and .env (created from .env.example).
function Get-Settings {
    $y = Read-TextFile 'config.yaml'
    $device = if ($y -match '(?m)^\s*device\s*:\s*"?([A-Za-z]+)') { $Matches[1].ToLower() } else { '' }
    switch ($device) {
        'gpu'  { $prof = 'gpu' }
        'cuda' { $prof = 'gpu' }
        'cpu'  { $prof = 'cpu' }
        default { Write-Host "config.yaml: 'device' must be gpu or cpu (found '$device')" -ForegroundColor Red; exit 1 }
    }
    foreach ($d in 'models', 'outputs', 'inputs') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    # server.port in config.yaml (the only "port:" key in the file)
    $port = if ($y -match '(?m)^\s+port\s*:\s*(\d+)') { [int]$Matches[1] } else { 5005 }
    # Remember the profile and port so plain `docker compose logs/restart/up` use the same settings.
    $envLines = @(Get-Content .env | Where-Object { $_ -notmatch '^(COMPOSE_PROFILES|MCP_PORT)=' }) +
        "COMPOSE_PROFILES=$prof" + "MCP_PORT=$port"
    Set-Content -Path .env -Value $envLines -Encoding ascii
    # IMAGE_REPO in .env: pull published images instead of building them here.
    $repo = ''
    $repoLine = Get-Content .env | Where-Object { $_ -match '^\s*IMAGE_REPO\s*=\s*(\S+)' } | Select-Object -First 1
    if ($repoLine -match '^\s*IMAGE_REPO\s*=\s*([^\s#]+)') { $repo = $Matches[1] }
    $image = if ($repo) { "${repo}:$prof" } else { "imagegen-mcp:$prof" }
    @{ Profile = $prof; Port = $port; ImageRepo = $repo; Image = $image }
}
function Test-ServerRunning {
    $r = Invoke-Program 'docker' @('ps', '--filter', 'name=^imagegen-mcp$', '--format', '{{.Names}}')
    ($r.Code -eq 0) -and [bool](($r.Out -join '').Trim())
}
# Step 4a. Builds the image (or pulls it with IMAGE_REPO) when it is missing, with -Force, or after an update changed
# the server code. Returns $false when that failed. Docker's output goes to the console (Out-Host), not into the result.
function Build-Image($s, [bool]$Force) {
    if (Test-Path $BuildMark) { $Force = $true }
    $have = (Invoke-Program 'docker' @('image', 'inspect', $s.Image)).Code -eq 0
    if ($have -and -not $Force) { Write-Host '==> Using the image server you already built.'; return $true }
    $ErrorActionPreference = 'Continue'
    if ($s.ImageRepo) {
        Write-Host "==> Downloading the image server ($($s.Image))..."
        docker compose --profile $s.Profile pull | Out-Host
        if ($LASTEXITCODE -eq 0) { Remove-Item $BuildMark -ErrorAction SilentlyContinue; return $true }
        Write-Host "The download failed (details are above). Check your internet connection, then run $Launcher again." -ForegroundColor Red
        return $false
    }
    if ($have) { Write-Host '==> Building the image server again (10-30 minutes)' }
    else { Write-Host '==> Building the image server (first time only, 10-30 minutes)' }
    Write-Host "    Docker's build output follows. Leave this window open until it finishes."
    docker compose --profile $s.Profile build | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Remove-Item $BuildMark -ErrorAction SilentlyContinue
        Write-Host '    The server is built.'
        return $true
    }
    Write-Host ''
    Write-Host 'The build failed (details are above). The usual causes:' -ForegroundColor Red
    Write-Host '  - No internet connection: check it.'
    Write-Host '  - The disk is full: free some space.'
    Write-Host '  - Not enough memory to compile: set BUILD_JOBS=4 (or 2) in .env.'
    Write-Host "Then run $Launcher again. The parts that finished are kept, so it continues where it stopped."
    $false
}
# Why `docker compose up` failed, and what to do.
function Show-UpError($s, [string]$Output) {
    @($Output -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }
    if ($Output -match 'port is already allocated|address already in use|Only one usage of each socket address') {
        Write-Host "Port $($s.Port) is used by another program. Close that program, or set another port in config.yaml" -ForegroundColor Red
        Write-Host "(server: port:), then run $Launcher again." -ForegroundColor Red
    } elseif ($Output -match 'could not select device driver|nvidia-container|capabilities: \[\[gpu\]\]') {
        Write-Host 'Docker cannot reach the NVIDIA GPU. Update the NVIDIA driver (570 or newer), restart the computer,' -ForegroundColor Red
        Write-Host "then run $Launcher again." -ForegroundColor Red
    } else {
        Write-Host "The server could not be started. Run $Launcher again; if it fails again, the details are in:" -ForegroundColor Red
        Write-Host '    docker compose logs --tail 80'
    }
}
# The server stopped while starting.
function Show-ServerError([string]$Message) {
    $short = if ($Message.Length -gt 400) { $Message.Substring(0, 400) } else { $Message }
    Write-Host "The server could not start: $short" -ForegroundColor Red
    if ($Message -match 'out of memory|OutOfMemory|cudaMalloc|failed to allocate') {
        Write-Host 'The model does not fit in memory. Run setup.cmd and choose a smaller model (Turbo needs the least).' -ForegroundColor Red
    } elseif ($Message -match 'driver version is insufficient|CUDA driver') {
        Write-Host "Update the NVIDIA driver to 570 or newer, then run $Launcher again." -ForegroundColor Red
    } elseif ($Message -match 'no CUDA device is visible') {
        Write-Host 'Docker cannot reach the NVIDIA GPU. Update the NVIDIA driver and Docker Desktop, restart the computer,' -ForegroundColor Red
        Write-Host "then run $Launcher again." -ForegroundColor Red
    } elseif ($Message -match 'disk space') {
        Write-Host "Free some disk space, then run $Launcher again. The download continues where it stopped." -ForegroundColor Red
    } elseif ($Message -match 'http|onnect|download') {
        Write-Host "The model download failed. Check your internet connection, then run $Launcher again." -ForegroundColor Red
        Write-Host 'The download continues where it stopped.' -ForegroundColor Red
    }
    Write-Host 'Details: docker compose logs --tail 80'
}
# Steps 4b and 4c. Shows the download and the model loading until the server is ready. Returns $false on an error.
function Wait-Ready($s, $m) {
    $said = ''; $line = ''
    while ($true) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$($s.Port)/api/status" -TimeoutSec 5 -ErrorAction Stop
            $h = $r.Content | ConvertFrom-Json
        } catch { $h = $null }
        if ($h) {
            switch ($h.state) {
                'downloading' {
                    $d = $h.download
                    if ($d.state -eq 'checking' -and -not $said) { Write-Host '==> Checking the model files...'; $said = 'checking' }
                    elseif ($d.state -eq 'downloading') {
                        if ($said -ne 'downloading') {
                            Write-Host "==> Downloading the model files (first time only, or after changing the model): $($d.total_gb) GB"
                            $said = 'downloading'
                        }
                        $pct = if ($d.percent -ne $null) { $d.percent } else { 0 }
                        $line = "    $($d.downloaded_gb) of $($d.total_gb) GB ($pct%)"
                        Write-Host -NoNewline "`r$line   "
                    }
                }
                'loading' {
                    if ($said -ne 'loading') {
                        if ($line) { Write-Host ''; $line = '' }
                        $where = Get-DeviceText $m
                        if ($where -eq 'CPU') { Write-Host '==> Loading the model on the CPU...' }
                        elseif ($where -like 'image model*') { Write-Host "==> Loading the model ($where)..." }
                        else { Write-Host "==> Loading the model on $where..." }
                        $said = 'loading'
                    }
                }
                'ready' { if ($line) { Write-Host '' }; return $true }
                'error' { if ($line) { Write-Host '' }; Show-ServerError "$($h.error)"; return $false }
            }
        }
        if (-not (Test-ServerRunning)) {
            if ($line) { Write-Host '' }
            Write-Host 'The server stopped while starting. Details: docker compose logs --tail 80' -ForegroundColor Red
            return $false
        }
        Start-Sleep -Seconds 2
    }
}
function Show-Ready($s) {
    Write-Host ''
    Write-Host 'Ready. Add this address to your AI app as an MCP server:' -ForegroundColor Green
    Write-Host "    http://localhost:$($s.Port)/mcp"
    Write-Host "Status page: http://localhost:$($s.Port) (open it in a browser)"
    Write-Host 'The server runs in the background, so you can close this window. It starts again with Docker.'
    Write-Host 'To change the settings, run setup.cmd. To stop the server, run stop.cmd.'
}
# Step 4. With 'ask', a running server is restarted only when the person wants to.
function Start-Server([string]$Mode, [bool]$Build) {
    $s = Get-Settings
    $m = Get-Machine
    if ($Mode -eq 'ask' -and (Test-ServerRunning) -and (Test-Interactive)) {
        Write-Host ''
        Write-Host 'The server is already running.'
        if (-not (Read-YesNo 'Restart it? (Only needed after you changed config.yaml by hand.)' $false)) {
            if (-not (Wait-Ready $s $m)) { exit 1 }
            Show-Ready $s
            return
        }
    }
    if (-not (Build-Image $s $Build)) { exit 1 }
    Write-Host '==> Starting the server...'
    Invoke-Program 'docker' @('compose', '--profile', 'gpu', '--profile', 'cpu', 'down', '--remove-orphans') | Out-Null
    Invoke-Program 'docker' @('rm', '-f', 'imagegen-mcp') | Out-Null
    $r = Invoke-Program 'docker' @('compose', '--profile', $s.Profile, 'up', '-d', '--no-build')
    if ($r.Code -ne 0 -and -not (Test-ServerRunning)) { Show-UpError $s (@($r.Out + $r.Err) -join "`n"); exit 1 }
    if (-not (Wait-Ready $s $m)) { exit 1 }
    Show-Ready $s
}
function Stop-Server {
    $r = Invoke-Program 'docker' @('compose', '--profile', 'gpu', '--profile', 'cpu', 'down')
    if ($r.Code -ne 0) {
        @($r.Out + $r.Err) | Where-Object { "$_".Trim() } | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }
        Write-Host 'The server could not be stopped. Is Docker running?' -ForegroundColor Red
        exit 1
    }
    Write-Host 'The server is stopped. Run start.cmd to start it again.'
}

# --- update ---------------------------------------------------------------------------------------------------------
# Install the latest version with git. config.yaml, .env, the models and the images are never touched.
function Invoke-Update {
    $download = "Download the latest version from $ProjectUrl and copy your config.yaml, .env and models folder into it."
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host 'Git is not installed, so this copy cannot update itself.'
        Write-Host $download
        return
    }
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'   # fail instead of waiting for a password
    try { Update-FromGit $download } finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
}
function Update-FromGit([string]$Download) {
    # --show-prefix is empty only when this folder is the top of a git copy.
    $r = Invoke-Git @('rev-parse', '--show-prefix')
    if ($r.Code -ne 0 -and ($r.Err -join ' ') -notmatch 'not a git repository') {
        Write-Host "Git reported an error: $(Get-FirstLine $r.Err)"
        return
    }
    if ($r.Code -ne 0 -or ($r.Out -join '').Trim()) {
        Write-Host 'This folder is not a git copy (it was probably downloaded as a ZIP), so it cannot update itself.'
        Write-Host $Download
        return
    }
    if ((Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')).Code -ne 0) {
        $branch = Get-FirstLine (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Out
        if ($branch -eq 'HEAD') { Write-Host 'This copy is not on a branch, so it cannot be updated.' }
        else { Write-Host "This copy is on branch '$branch', which does not follow a branch on GitHub, so it cannot be updated." }
        return
    }
    Write-Host '==> Checking for updates...'
    if ((Invoke-Git @('fetch', '--quiet')).Code -ne 0) {
        Write-Host "Could not reach GitHub. Check your internet connection, then run $Launcher again."
        return
    }
    $behind = [int](Get-FirstLine (Invoke-Git @('rev-list', '--count', 'HEAD..@{u}')).Out)
    $ahead = [int](Get-FirstLine (Invoke-Git @('rev-list', '--count', '@{u}..HEAD')).Out)
    if ($behind -eq 0) { Write-Host 'You already have the latest version.'; return }
    if ($behind -eq 1) { Write-Host '1 update is available:'; $them = 'it' } else { Write-Host "$behind updates are available:"; $them = 'them' }
    (Invoke-Git @('log', '--oneline', '--no-decorate', '--reverse', '-n', '15', 'HEAD..@{u}')).Out | ForEach-Object { Write-Host "    $_" }
    if ($behind -gt 15) { Write-Host "    ... and $($behind - 15) more" }
    if (-not (Read-YesNo "Install $them now?" $true)) { return }

    $old = Get-FirstLine (Invoke-Git @('rev-parse', 'HEAD')).Out
    $r = $null
    if ($ahead -eq 0) { $r = Invoke-Git @('merge', '--ff-only', '--quiet', '@{u}') }
    if ($ahead -ne 0 -or $r.Code -ne 0) {
        $changed = @((Invoke-Git @('status', '--porcelain', '--untracked-files=no')).Out | Where-Object { $_.Length -gt 3 } |
                     ForEach-Object { $_.Substring(3) })
        Write-Host ''
        Write-Host 'The update cannot be installed because this copy was changed on this computer:'
        $changed | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
        if ($ahead -ne 0) { Write-Host "    $ahead commit(s) made on this computer" }
        if ($changed.Count -eq 0 -and $ahead -eq 0) {
            @($r.Err + $r.Out) | Where-Object { "$_".Trim() } | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
        }
        Write-Host 'Your settings (config.yaml, .env), the models and your images are not affected.'
        Write-Host ''
        Write-Host '  1) Cancel the update and keep the changes'
        Write-Host '  2) Discard the changes and install the update'
        if ((Read-Choice 2 1) -eq 1) { Write-Host 'Nothing was changed.'; return }
        # Keep a copy for people who know git: the changed files in a stash, the old version in a branch.
        if ($changed.Count -gt 0) { Invoke-Git @('stash', 'push', '--quiet', '-m', 'changes before update') | Out-Null }
        Invoke-Git @('branch', '-f', 'before-update', $old) | Out-Null
        $r = Invoke-Git @('reset', '--hard', '--quiet', '@{u}')
        if ($r.Code -ne 0) { Write-Host "The update failed: $(Get-FirstLine $r.Err)" -ForegroundColor Red; exit 1 }
        Write-Host "    The changes were discarded. (A copy is kept in git: 'git stash list' and the branch before-update.)"
    }
    Write-Host ''
    Write-Host '==> Update installed. Your settings in config.yaml were kept.'
    # Only these paths go into the Docker image (see .dockerignore); other changes need just a restart.
    $diff = Invoke-Git @('diff', '--name-only', $old, 'HEAD', '--', 'Dockerfile', 'pyproject.toml', 'src', 'docker/patches')
    $serverChanged = @($diff.Out | Where-Object { "$_".Trim() }).Count -gt 0
    if ($serverChanged) { Set-Content -Path $BuildMark -Value 'the update changed the server' -Encoding ascii }
    if (-not (Test-Path (Join-Path $Root 'config.yaml'))) { Write-Host 'Run start.cmd to set it up and start it.'; return }
    if ($serverChanged) { Write-Host '    The server itself changed, so it is built again when it starts (10-30 minutes).' }
    if (Read-YesNo 'Start the new version now?' $true) {
        # A new PowerShell runs the new start script (git just replaced it): it builds the image if needed and
        # restarts the server.
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\imagegen.ps1') start -Restart
        exit $LASTEXITCODE
    }
    Write-Host 'Run start.cmd to use the new version.'
}
