# Image Gen MCP: the shared code of scripts\imagegen.ps1 (setup.cmd, start.cmd, update.cmd and stop.cmd run it).
#   step 1  Test-Docker     Docker is installed and running
#   2-3b    Invoke-Setup    where the server runs and which model it uses, saved in config.yaml
#   step 4  Start-Server    build the image, start the server, download the model, wait until it is loaded
#           Invoke-Update   install the latest version with git
# Uses $Root and $Launcher from imagegen.ps1. Keep this file ASCII only (PowerShell 5.1).
# Keep the texts and the model choices the same as in scripts/lib.sh (tests/test_start_scripts.py checks them).

# The model choices, the same rows as in scripts/lib.sh (tests/test_start_scripts.py checks the files against
# src/imagegen_mcp/models.py): name|variant|quant|text encoder quant|seconds per 1024x1024 image on an RTX 3080 Ti|
# memory for Docker in GB|image model file|its bytes|text encoder file|its bytes
$Presets = @(
    'Best quality|uncensored|Q4_K_M|Q8_0|90|20|diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf|4604558112|text_encoders/Qwen3VL-8B-Instruct-Q8_0.gguf|8709519456'
    'Standard|uncensored|Q4_K_M|Q4_K_M|90|16|diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf|4604558112|text_encoders/Qwen3VL-8B-Instruct-Q4_K_M.gguf|5027784800'
    'Turbo|turbo|Q4_K_M|Q4_K_M|12|16|diffusion_models/Qwen-Image-2.1-Turbo-AD-Q4_K.gguf|4201694944|text_encoders/Qwen3VL-8B-Instruct-Q4_K_M.gguf|5027784800'
) | ForEach-Object {
    $f = $_ -split '\|'
    [pscustomobject]@{ Name = $f[0]; Variant = $f[1]; Quant = $f[2]; TE = $f[3]; Sec = $f[4]; RamGB = $f[5]
                       ImageFile = $f[6]; ImageBytes = [int64]$f[7]; TEFile = $f[8]; TEBytes = [int64]$f[9] }
}
# The files that every model choice needs: path|bytes (under models\).
$SharedFiles = @(
    'text_encoders/mmproj-Qwen3VL-8B-Instruct-F16.gguf|1159029824'
    'vae/texture_fix_vae_for_qwen_image_2.1_bf16.safetensors|675509688'
    'background_removal/birefnet-general-lite.onnx|224005088'
    'loras/watermark_remover_v2_qwen.safetensors|79744288'
    'upscalers/4xNomos2_otf_esrgan.safetensors|33467822'
)
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
    # FormKC turns full-width digits (Japanese and Chinese input methods) into 0-9.
    $a = "$(Read-Host "$Prompt [$Default]")".Normalize([Text.NormalizationForm]::FormKC).Trim()
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
        if ($a -match '^[0-9]{1,2}$' -and [int]$a -ge 1 -and [int]$a -le $Max) { return [int]$a }
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
# All has both in the order the program wrote them. A program that is not installed returns Code -1.
function Invoke-Program([string]$Exe, [string[]]$ArgList) {
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Code = -1; Out = @(); Err = @("$Exe is not installed"); All = @("$Exe is not installed") }
    }
    $ErrorActionPreference = 'Continue'
    $out = New-Object Collections.Generic.List[string]
    $err = New-Object Collections.Generic.List[string]
    $all = New-Object Collections.Generic.List[string]
    & $Exe @ArgList 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $err.Add("$_") } else { $out.Add("$_") }
        $all.Add("$_")
    }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out); Err = @($err); All = @($all) }
}
function Invoke-Git([string[]]$ArgList) { Invoke-Program 'git' (@('--no-pager', '-C', $Root) + $ArgList) }
function Get-FirstLine($Lines) { @($Lines | Where-Object { "$_".Trim() })[0] }

# --- config.yaml ----------------------------------------------------------------------------------------------------
# Set "key: value" in YAML text, keeping the rest of the line (its comment). With a section, only that top-level
# section is searched (vae: is both in model: and in gpu:).
function Set-Yaml([string]$Text, [string]$Key, [string]$Value, [string]$Section = '') {
    $item = '(\{[^}\r\n]*\}|\[[^\]\r\n]*\]|[^\s#]*)'
    $name = if ($Section) { "$Section.$Key" } else { $Key }
    if (-not $Section) {
        $km = ([regex]"(?m)^($Key[ \t]*:[ \t]*)$item").Match($Text)
        if ($km.Success) { return Set-YamlMatch $km $Text $Value $name }
        return "${Key}: $Value`n$Text"
    }
    # The section: from its "name:" line to the next top-level key.
    $m = ([regex]"(?ms)^$Section[ \t]*:[^\r\n]*\r?\n(.*?)(?=^[A-Za-z_]|\z)").Match($Text)
    if ($m.Success) {
        $body = $m.Groups[1]
        $km = ([regex]"(?m)^([ \t]+$Key[ \t]*:[ \t]*)$item").Match($body.Value)
        if ($km.Success) {
            return $Text.Substring(0, $body.Index) + (Set-YamlMatch $km $body.Value $Value $name) +
                $Text.Substring($body.Index + $body.Length)
        }
    }
    $val = $Value.Replace('$', '$$')
    $sec = [regex]"(?m)^$Section[ \t]*:[ \t]*(#[^\r\n]*)?(?=\r?$)"
    if ($sec.IsMatch($Text)) { return $sec.Replace($Text, "`$0`n  ${Key}: $val", 1) }
    if ($Text -match "(?m)^$Section[ \t]*:") { throw "config.yaml: change $name by hand (this layout is not supported)" }
    return $Text.TrimEnd() + "`n${Section}:`n  ${Key}: $Value`n"
}
# Replace the value of one matched "key: value" line (group 1: up to the value, group 2: the value).
function Set-YamlMatch($M, [string]$Text, [string]$Value, [string]$Name) {
    $head = $M.Groups[1].Value
    $after = $Text.Substring($M.Index + $M.Length)
    if (-not $M.Groups[2].Value) {
        # No value on the line and more-indented lines below it: a block list or map, which is not changed here.
        $indent = $head.Length - $head.TrimStart().Length
        if ($after -match '^[^\r\n]*\r?\n(?:[ \t]*\r?\n)*([ \t]*)[^ \t\r\n#]' -and $Matches[1].Length -gt $indent) {
            throw "config.yaml: change $Name by hand (this layout is not supported)"
        }
    }
    if ($head -notmatch '\s$') { $head += ' ' }
    $Text.Substring(0, $M.Index) + $head + $Value + $after
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
# Text = "Standard (uncensored Q4_K_M, text encoder Q4_K_M)" or "custom (...)", Choice = it as a model choice.
function Get-CurrentModel {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'config.yaml'))) { return [pscustomobject]@{ Text = ''; Index = 0; Choice = $null } }
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
            return [pscustomobject]@{ Text = "$($p.Name) ($d)"; Index = $i + 1; Choice = $p }
        }
    }
    $custom = [pscustomobject]@{ Name = 'custom'; Variant = $v; Quant = $q; TE = $t; Sec = ''; RamGB = ''
                                 ImageFile = ''; ImageBytes = [int64]0; TEFile = ''; TEBytes = [int64]0 }
    [pscustomobject]@{ Text = "custom ($d)"; Index = 0; Choice = $custom }
}
# The saved device and GPU places: Device, Img ("0" or "0 2"), TE ("2", "ram" or "cpu") and Dec ("2" or "cpu").
# Empty without config.yaml.
function Read-Current {
    $c = @{ Device = ''; Img = ''; TE = ''; Dec = '' }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'config.yaml'))) { return $c }
    $y = Read-TextFile 'config.yaml'
    if ($y -match '(?m)^device[ \t]*:[ \t]*"?([A-Za-z]+)') { $c.Device = $Matches[1].ToLower() }
    $c.Img = @((Get-YamlValue $y 'gpu' 'diffusion') -replace '[\[\]]', '' -split '[,\s]+' | Where-Object { $_ }) -join ' '
    if (-not $c.Img) { $c.Img = '0' }
    $first = ($c.Img -split ' ')[0]
    $c.TE = Get-YamlValue $y 'gpu' 'text_encoder'; if (-not $c.TE) { $c.TE = $first }
    $c.Dec = Get-YamlValue $y 'gpu' 'vae'; if (-not $c.Dec) { $c.Dec = $first }
    # offload: {text_encoder: cpu} keeps the text encoder's weights in RAM while it runs on its GPU.
    if ((Get-YamlValue $y 'gpu' 'offload') -match 'text_encoder\s*:\s*cpu' -and $c.TE -ne 'cpu') { $c.TE = 'ram' }
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
# "GPU 2 (NVIDIA ..., 12 GB)", "CPU (...)" or, for the text encoder, "RAM, runs on GPU 2" (-Img: the image model's GPUs).
function Get-PlaceLabel($m, [string]$Place, [string]$Img = '') {
    if ($Place -eq 'cpu') { return "CPU ($(Get-CpuName))" }
    if ($Place -eq 'ram') { return "RAM, runs on GPU $(($Img -split ' ')[0])" }
    (@($Place -split ' ') | ForEach-Object { Get-GpuLabel $m ([int]$_) }) -join ' + '
}
# "CPU", "RAM", "GPU 2" or "GPU 0 + GPU 2".
function Get-PlaceShort([string]$Place) {
    switch ($Place) { 'cpu' { 'CPU' } 'ram' { 'RAM' } default { 'GPU ' + (($Place -split ' ') -join ' + GPU ') } }
}
# "image model on GPU 0 + GPU 2, text encoder in RAM, image decoder on GPU 2".
function Get-PartsText([string]$Img, [string]$TE, [string]$Dec) {
    $t = if ($TE -eq 'ram') { 'text encoder in RAM' } else { "text encoder on $(Get-PlaceShort $TE)" }
    "image model on $(Get-PlaceShort $Img), $t, image decoder on $(Get-PlaceShort $Dec)"
}
# Where the server runs, from config.yaml: "CPU", "GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)" or a split.
function Get-DeviceText($m) {
    $c = Read-Current
    if ($c.Device -eq 'cpu') { return 'CPU' }
    if ($c.Img -notmatch ' ' -and $c.Dec -eq $c.Img -and ($c.TE -eq $c.Img -or $c.TE -eq 'ram')) {
        $one = if ($c.Img -match '^[0-9]+$' -and (Get-Gpu $m ([int]$c.Img))) { Get-GpuLabel $m ([int]$c.Img) } else { "GPU $($c.Img)" }
        if ($c.TE -eq 'ram') { return "$one, text encoder in RAM" }
        return $one
    }
    Get-PartsText $c.Img $c.TE $c.Dec
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
    $r = Invoke-Program 'docker' @('info')
    if ($r.Code -ne 0 -and ($r.All -join ' ') -match 'Access is denied|permission denied') {
        Write-Host 'Docker Desktop is running, but your Windows user may not use it yet. Sign out of Windows and sign in' -ForegroundColor Red
        Write-Host "again (that makes the docker-users group work), then run $Launcher again." -ForegroundColor Red
        exit 1
    }
    if ($r.Code -ne 0) {
        Write-Host 'Docker is installed but not running. Start Docker Desktop, wait until it says Engine running,' -ForegroundColor Red
        Write-Host "then run $Launcher again." -ForegroundColor Red
        exit 1
    }
    Write-Host '    Docker is running.'
}

# --- step 2: which GPU ----------------------------------------------------------------------------------------------
# Show the GPUs; with more than one, ask which one to use. Returns @{ List = GPU numbers; Split = $true/$false }.
# A GPU gets every part of the model. The last choice, custom load, is set up after the model is chosen
# (Invoke-Split), because where the parts fit depends on the model's size.
# The GPU with the most memory (the first one of those).
function Get-LargestGpu($m) { @($m.Gpus | Sort-Object -Property @{ Expression = 'GB'; Descending = $true }, Index)[0].Index }
# The model choice that a GPU of this size suits best, and whether all of it fits on the GPU.
function Get-GpuFit($m, [int]$GB) {
    $cap = if ($GB -lt 20) { $GB - 2 } else { $GB }
    if ($GB -lt 4) { return 'too small' }
    if ($GB -lt 8) { return 'Turbo, slower' }
    if ($GB -lt 12) { return 'Turbo' }
    $p = if ($m.DockerGB -eq 0 -or $m.DockerGB -ge 20) { $Presets[0] } else { $Presets[1] }
    if ((Get-GpuNeed $p) -le $cap) { "$($p.Name), all on the GPU" } else { "$($p.Name), some weights in RAM" }
}
function Select-Gpu($m, [string]$Default) {
    if ($m.GpuCount -eq 1) {
        Write-Host "    GPU: $($m.Gpus[0].Name), $($m.Gpus[0].GB) GB ($(Get-GpuFit $m $m.Gpus[0].GB))"
        return @{ List = @($m.Gpus[0].Index); Split = $false }
    }
    $best = Get-LargestGpu $m
    Write-Host '    GPUs found:'
    foreach ($g in $m.Gpus) {
        $mark = if ($g.Index -eq $best) { '  <- recommended' } else { '' }
        Write-Host ('      {0,-38} {1}{2}' -f "$($g.Index)) $($g.Name), $($g.GB) GB", (Get-GpuFit $m $g.GB), $mark)
    }
    Write-Host "      $($m.GpuCount)) Custom load (multi-GPU and CPU)"
    Write-Host ''
    Write-Host 'Which GPU should the image server use?'
    while ($true) {
        $a = Read-Answer 'Type a number and press Enter' $Default
        if ($a -match '^[0-9]{1,2}$') {
            if ([int]$a -eq $m.GpuCount) {
                Write-Host '    The custom load is set up after you choose the model.'
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
    if ($m.Mac -or $m.GpuCount -gt 0) { Write-Host "Nothing was changed. Run $Launcher again when you want to set it up." }
    else { Write-Host "Nothing was changed. If you have an NVIDIA GPU, install its driver, then run $Launcher again." }
    exit 0
}

# --- step 3: the model ----------------------------------------------------------------------------------------------
# Device and recommended choice for the GPU memory in VramGB (the total when the model is split).
function Get-Recommendation($m) {
    if ($m.Mac -or $m.VramGB -lt 4) { return @{ Device = 'cpu'; Preset = $TurboChoice } }
    $preset = if ($m.VramGB -lt 12) { $TurboChoice } elseif ($m.DockerGB -ge 20) { 1 } else { 2 }
    @{ Device = 'gpu'; Preset = $preset }
}
# The bytes that a model choice still has to download (files that are missing or not complete).
function Get-MissingBytes($Preset) {
    $sum = [int64]0
    $files = @("$($Preset.ImageFile)|$($Preset.ImageBytes)", "$($Preset.TEFile)|$($Preset.TEBytes)") + $SharedFiles
    foreach ($row in $files) {
        $path, $bytes = $row -split '\|'
        if (-not $path) { continue }
        $full = Join-Path (Join-Path $Root 'models') $path
        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -ne [int64]$bytes) { $sum += [int64]$bytes }
    }
    $sum
}
# GB of GPU memory for the whole model on one GPU: the image model and the text encoder, the decoder (0.7 GB) and the
# working memory of the largest step (about 4 GB at 1024x1024). See Get-GpuWarnings.
function Get-GpuNeed($Preset) { [int][math]::Floor(($Preset.ImageBytes + $Preset.TEBytes) / 1e9 + 0.7 + 4 + 0.5) }
# With -Custom (the text of a model that is none of the choices), a last line offers to keep it.
function Show-Presets([int]$Recommended, [bool]$Cpu, [int]$Current, [string]$Custom = '') {
    if ($Cpu) { Write-Host '    Choice          Download     Memory       Time per image' }
    else { Write-Host '    Choice          Download     GPU memory   Time per image' }
    for ($i = 0; $i -lt $Presets.Count; $i++) {
        $p = $Presets[$i]
        $missing = Get-MissingBytes $p
        $dl = if ($missing -eq 0) { 'downloaded' } else { '{0:0.0} GB' -f ($missing / 1e9) }
        $mem = if ($Cpu) { "$($p.RamGB) GB" } else { "$(Get-GpuNeed $p) GB" }
        $time = if ($Cpu) { 'minutes' } else { "~$($p.Sec) s" }
        $mark = ''
        if ($i + 1 -eq $Current -and $i + 1 -eq $Recommended) { $mark = '  <- current, recommended' }
        elseif ($i + 1 -eq $Current) { $mark = '  <- current' }
        elseif ($i + 1 -eq $Recommended) { $mark = '  <- recommended' }
        $line = ' {0}) {1,-15} {2,-12} {3,-12} {4}' -f ($i + 1), $p.Name, $dl, $mem, $time
        if ($mark) { Write-Host "$line$mark" -ForegroundColor Green } else { Write-Host $line }
    }
    if ($Custom) { Write-Host (' {0}) Keep the current model: {1}  <- current' -f ($Presets.Count + 1), $Custom) -ForegroundColor Green }
    Write-Host ''
    if ($Cpu) { Write-Host ' Memory: what Docker needs. On the CPU, each image takes several minutes.' }
    else {
        Write-Host ' GPU memory: the whole model on the GPU. A smaller GPU keeps some weights in RAM: the same speed on 12 GB,'
        Write-Host ' slower with less.'
        Write-Host ' Times: one 1024x1024 image on an RTX 3080 Ti.'
    }
    Write-Host " 1 and 2 use the uncensored model. $TurboChoice uses the official Turbo model: much faster, weaker at small text."
}
# Best quality needs about 18 GB of memory: ask before using it when Docker has less than 20 GB.
function Confirm-Choice([int]$Choice, $m) {
    if ($Choice -ne 1 -or $m.DockerGB -le 0 -or $m.DockerGB -ge 20) { return $true }
    Write-Host "Best quality needs 20 GB of memory for Docker, but Docker can use only $($m.DockerGB) GB." -ForegroundColor Yellow
    Read-YesNo 'Use it anyway?' $false
}

# --- step 3b: where each part of the model runs (only after "Split") ------------------------------------------------
# Sizes in GB of the parts of a model choice (the files the server loads), as text so they print like lib.sh.
function Get-ImageGB($Preset) {
    if ($Preset.ImageBytes -gt 0) { return '{0:0.0}' -f ($Preset.ImageBytes / 1e9) }
    switch ($Preset.Quant) { 'Q6_K' { '5.9' } 'Q8_0' { '7.6' } default { if ($Preset.Variant -eq 'turbo') { '4.2' } else { '4.6' } } }
}
function Get-EncoderGB($Preset) {
    if ($Preset.TEBytes -gt 0) { return '{0:0.0}' -f ($Preset.TEBytes / 1e9) }
    switch ($Preset.TE) { 'Q8_0' { '8.7' } 'F16' { '16.4' } default { '5.0' } }
}
$DecoderGB = '0.7'
# The menu number for a saved place. Kind: image, te or dec. Host: the first GPU of the image model. Without a valid
# saved place: the first GPU for the image model; RAM for the text encoder on a GPU under 20 GB (else that GPU); the
# image model's GPU for the image decoder. RAM needs 8 GB or more on the host GPU.
function Get-PartDefault($m, [string]$Place, [string]$Kind, [string]$HostGpu = '') {
    $n = $m.GpuCount
    if ($Kind -eq 'image' -and $Place -match ' ') { return "$n" }
    if ($Kind -eq 'te' -and $Place -eq 'ram') { return "$n" }
    if ($Kind -eq 'te' -and $Place -eq 'cpu') { return "$($n + 1)" }
    if ($Kind -eq 'dec' -and $Place -eq 'cpu') { return "$n" }
    if ($Place -match '^[0-9]+$' -and (Get-Gpu $m ([int]$Place))) { return $Place }
    switch ($Kind) {
        'image' { return "$($m.Gpus[0].Index)" }
        'te' {
            $gb = (Get-Gpu $m ([int]$HostGpu)).GB
            if ($gb -ge 8 -and $gb -lt 20) { return "$n" } else { return $HostGpu }
        }
        default { return $HostGpu }
    }
}
# Ask where one part runs. Kind: image, te or dec. Returns a GPU number, several (image model, separated by spaces),
# 'ram' (text encoder: weights in RAM, runs on HostGpu) or 'cpu'.
function Read-Place($m, [string]$Name, [string]$GB, [string]$Kind, [string]$Default, [string]$Saved = '', [string]$HostGpu = '') {
    $n = $m.GpuCount
    Write-Host ''
    Write-Host "$Name ($GB GB): where should it run?"
    foreach ($g in $m.Gpus) { Write-Host "  $($g.Index)) GPU $($g.Index): $($g.Name), $($g.GB) GB" }
    switch ($Kind) {
        'image' { Write-Host "  $n) Several GPUs (split it)" }
        'te' {
            $gb = (Get-Gpu $m ([int]$HostGpu)).GB
            $rec = if ($gb -lt 8) { "  (needs 8 GB or more on GPU $HostGpu)" } elseif ($gb -lt 20) { '  <- recommended' } else { '' }
            Write-Host "  $n) RAM: the weights stay in RAM, it runs on GPU $HostGpu$rec"
            Write-Host "  $($n + 1)) CPU: $(Get-CpuName) (slow)"
        }
        default { Write-Host "  $n) CPU: $(Get-CpuName) (slow)" }
    }
    $max = if ($Kind -eq 'te') { $n + 1 } else { $n }
    while ($true) {
        $a = Read-Answer 'Type a number and press Enter' $Default
        if ($a -match '^[0-9]{1,2}$') {
            if (Get-Gpu $m ([int]$a)) { return "$([int]$a)" }
            $k = [int]$a - $n
            if ($Kind -eq 'image' -and $k -eq 0) { return (Read-GpuList $m $Saved) }
            if ($Kind -eq 'te' -and $k -eq 0) {
                # With less than 8 GB the explicit RAM setting stops the engine's auto-fit, and images fail.
                if ((Get-Gpu $m ([int]$HostGpu)).GB -ge 8) { return 'ram' }
                Write-Host "The text encoder in RAM needs 8 GB or more on GPU $HostGpu. Choose a GPU or the CPU."
                continue
            }
            if (($Kind -eq 'te' -and $k -eq 1) -or ($Kind -eq 'dec' -and $k -eq 0)) { return 'cpu' }
        }
        Write-Host "Please type a number from 0 to $max."
    }
}
# Two or more GPUs for the image model (the saved ones are the default).
function Read-GpuList($m, [string]$Saved) {
    $all = ($m.Gpus | ForEach-Object { $_.Index }) -join ','
    $default = if ($Saved -match ' ') { $Saved -replace ' ', ',' } else { $all }
    while ($true) {
        $a = Read-Answer 'Which GPUs? Type their numbers separated by commas' $default
        $parts = @($a -split '[,\s]+' | Where-Object { $_ })
        $ok = $parts.Count -ge 2 -and @($parts | Where-Object { $_ -notmatch '^[0-9]{1,2}$' -or -not (Get-Gpu $m ([int]$_)) }).Count -eq 0 -and
              @($parts | Select-Object -Unique).Count -eq $parts.Count
        if ($ok) { return (@($parts | ForEach-Object { [int]$_ }) -join ' ') }
        $default = $all
        Write-Host "Please type two or more different GPU numbers from the list, for example $all."
    }
}
# A line for each GPU that may run out of memory with these places (TE 'ram': its weights in RAM, it runs on the
# first GPU of Img). A GPU needs its model files plus the working memory of the largest step that runs on it (the steps
# run one after another): the image model about 3 GB, the image decoder about 4 GB (1024x1024), the text encoder
# 1.5-2.2 GB. When the files do not fit, the engine's auto-fit keeps the weights of the text encoder and the decoder in
# RAM by itself (about 0.2 GB each on the GPU), at the same speed. The limit is the memory minus 2 GB. Measured on a
# 12 GB GPU: Turbo with every part on the GPU runs in 11.5 s (auto-fit moved the text encoder and decoder weights to
# RAM); a 5 GB image model makes the decoder fall back to tiles.
function Get-GpuWarnings($m, [string]$Img, [string]$TE, [string]$Dec, $Preset) {
    $ig = [double](Get-ImageGB $Preset); $eg = [double](Get-EncoderGB $Preset)
    $imgs = @($Img -split ' ')
    foreach ($g in $m.Gpus) {
        $files = 0.0; $fit = 0.0; $work = 0.0; $id = "$($g.Index)"
        if ($imgs -contains $id) { $files += $ig / $imgs.Count; $fit += $ig / $imgs.Count; $work = 3 }
        if ($TE -eq 'ram' -and $imgs[0] -eq $id) { $files += 0.2; $fit += 0.2; $work = [math]::Max($work, 1.5) }
        if ($TE -eq $id) { $files += $eg; $fit += 0.2; $work = [math]::Max($work, 2.2) }
        if ($Dec -eq $id) { $files += 0.7; $fit += 0.2; $work = [math]::Max($work, 4) }
        $need = $files + $work
        if ($need -gt $g.GB - 2) { $need = $fit + $work }   # auto-fit keeps the text encoder and decoder weights in RAM
        if ($files -gt 0 -and $need -gt $g.GB - 2) {
            '    GPU {0} ({1}, {2} GB) may run out of memory: its parts need about {3} GB.' -f $g.Index, $g.Name, $g.GB,
                [int][math]::Floor($need + 0.5)
        }
    }
}
# On one GPU, a note when the model does not fit in the GPU's limit even with the text encoder's and the decoder's
# weights in RAM (the image model, about 0.4 GB for those two, and the working memory of the largest step, the decoder's
# 4 GB at 1024x1024). The engine then keeps part of the image model in RAM or decodes in tiles, so each image takes
# longer (measured on a real RTX 3080 10 GB: the decoder fell back to tiles).
function Show-SlowNote($m, [string]$Gpu, $Preset) {
    $gb = (Get-Gpu $m ([int]$Gpu)).GB
    $cap = if ($gb -lt 20) { $gb - 2 } else { $gb }
    if ([double](Get-ImageGB $Preset) + 0.4 + 4 -gt $cap) {
        Write-Host ''
        Write-Host '    This GPU is small for the whole model: the server keeps part of it in RAM, so each image takes longer.' -ForegroundColor Yellow
    }
}
# Print the memory warnings, if any. Returns $true when there were some.
function Show-Warnings($m, [string]$Img, [string]$TE, [string]$Dec, $Preset) {
    $warn = @(Get-GpuWarnings $m $Img $TE $Dec $Preset)
    if ($warn.Count -eq 0) { return $false }
    Write-Host ''
    $warn | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Write-Host '    The server then works more slowly (it moves parts to RAM) or stops with an out-of-memory error.' -ForegroundColor Yellow
    $true
}
# The custom load: place the image model, the text encoder and the image decoder one by one, then show all three with
# a warning for any GPU that may run out of memory, and confirm or start over. Returns @{ Img; TE; Dec }.
function Invoke-Split($m, $Preset, $Cur) {
    $ig = Get-ImageGB $Preset; $eg = Get-EncoderGB $Preset
    Write-Host ''
    Write-Host "Custom load for $($Preset.Name): choose where each part of the model runs."
    while ($true) {
        $img = Read-Place $m 'Image model' $ig 'image' (Get-PartDefault $m $Cur.Img 'image') $Cur.Img
        $hostGpu = ($img -split ' ')[0]
        $te = Read-Place $m 'Text encoder' $eg 'te' (Get-PartDefault $m $Cur.TE 'te' $hostGpu) '' $hostGpu
        $dec = Read-Place $m 'Image decoder' $DecoderGB 'dec' (Get-PartDefault $m $Cur.Dec 'dec' $hostGpu) '' $hostGpu
        Write-Host ''
        Write-Host 'Your custom load:'
        Write-Host ('    {0,-24} {1}' -f "Image model ($ig GB):", (Get-PlaceLabel $m $img))
        Write-Host ('    {0,-24} {1}' -f "Text encoder ($eg GB):", (Get-PlaceLabel $m $te $img))
        Write-Host ('    {0,-24} {1}' -f "Image decoder ($DecoderGB GB):", (Get-PlaceLabel $m $dec))
        Show-Warnings $m $img $te $dec $Preset | Out-Null
        Write-Host ''
        Write-Host '  1) Confirm'
        Write-Host '  2) Start over'
        if ((Read-Choice 2 1) -eq 1) { return @{ Img = $img; TE = $te; Dec = $dec } }
    }
}

# --- saving the answers ---------------------------------------------------------------------------------------------
# GPU settings in config.yaml text: the GPU places and a memory limit for each GPU under 20 GB. TE 'ram': the text
# encoder runs on the image model's (first) GPU with its weights in RAM. Otherwise offload auto: the engine keeps weights
# in RAM only when they do not fit. Returns @{ Text; Note }.
function Set-GpuConfig([string]$Text, $m, [string]$Img, [string]$TE, [string]$Dec) {
    $imgs = @($Img -split ' ')
    $used = @(@($imgs + $TE + $Dec) | Where-Object { $_ -ne 'cpu' -and $_ -ne 'ram' } | ForEach-Object { [int]$_ } |
              Sort-Object -Unique)
    $caps = @(); $limits = @()
    foreach ($i in $used) {
        $gb = (Get-Gpu $m $i).GB
        if ($gb -lt 20) { $caps += "${i}: $($gb - 2)"; $limits += "GPU $i limited to $($gb - 2) GB" }
    }
    $offload = 'auto'; $teGpu = $TE
    if ($TE -eq 'ram') { $offload = '{text_encoder: cpu}'; $teGpu = $imgs[0] }
    $cache = if ($caps.Count -gt 0) { 'q8_0' } else { 'auto' }
    $Text = Set-Yaml $Text 'diffusion' "[$($imgs -join ', ')]" 'gpu'
    $Text = Set-Yaml $Text 'text_encoder' $teGpu 'gpu'
    $Text = Set-Yaml $Text 'vae' $Dec 'gpu'
    $Text = Set-Yaml $Text 'max_vram_gb' "{$($caps -join ', ')}" 'gpu'
    $Text = Set-Yaml $Text 'offload' $offload 'gpu'
    $Text = Set-Yaml $Text 'prefix_cache_type' $cache 'generation'
    if ($imgs.Count -eq 1 -and $Dec -eq $Img -and ($TE -eq $Img -or $TE -eq 'ram')) {
        $i = [int]$Img; $gb = (Get-Gpu $m $i).GB
        $note = "GPU $i"
        if ($gb -lt 20) { $note += " (limited to $($gb - 2) GB)" }
        if ($TE -eq 'ram') { $note += ', text encoder in RAM' }
    } else {
        $note = Get-PartsText $Img $TE $Dec
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
    $haveConfig = Test-Path -LiteralPath (Join-Path $Root 'config.yaml')
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
        $default = "$(Get-LargestGpu $m)"
        if ($cur.Device -eq 'gpu') {
            if ($cur.Img -ne $cur.TE -or $cur.TE -ne $cur.Dec) { $default = "$($m.GpuCount)" }   # a custom load
            elseif ($cur.Img -match '^[0-9]+$' -and (Get-Gpu $m ([int]$cur.Img))) { $default = $cur.Img }
        }
        $total = (@($m.Gpus | ForEach-Object { $_.GB }) | Measure-Object -Sum).Sum
        while ($true) {
            $sel = Select-Gpu $m $default
            $m.VramGB = (@($sel.List | ForEach-Object { (Get-Gpu $m $_).GB }) | Measure-Object -Sum).Sum
            if ($m.VramGB -ge 4 -or $m.GpuCount -eq 1 -or $total -lt 4) { break }
            Write-Host ''
            Write-Host "That GPU has only $($m.VramGB) GB of memory (4 GB or more is needed). Choose another GPU or the custom load." -ForegroundColor Yellow
            $default = "$($m.GpuCount)"
        }
        if ($m.VramGB -lt 4) {
            Confirm-Cpu "That GPU has only $($m.VramGB) GB of memory (4 GB or more is needed), so the server can only run on the CPU." $m
            $sel = $null
        } elseif ($m.VramGB -lt 8) {
            Write-Host ''
            Write-Host "Note: with less than 8 GB, the server keeps most of the model in RAM. Use choice $TurboChoice (Turbo). Each image" -ForegroundColor Yellow
            Write-Host 'takes longer, and Docker needs about 16 GB of memory.' -ForegroundColor Yellow
        } elseif ($m.VramGB -lt 12) {
            Write-Host ''
            Write-Host "Note: choice $TurboChoice (Turbo) fits this GPU best." -ForegroundColor Yellow
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

    # Step 3: the model. On one GPU the engine always fits the model (auto-fit), so there is only a note when it will
    # be slower. A custom load gets the memory check (Invoke-Split).
    $place = $null
    while ($true) {
        Write-Host ''
        if (-not $sel) { Write-Host 'Which model do you want to use? (on the CPU)' }
        elseif ($sel.Split) { Write-Host 'Which model do you want to use? (custom load)' }
        else { $g = Get-Gpu $m $sel.List[0]; Write-Host "Which model do you want to use? (on GPU $($g.Index): $($g.Name), $($g.GB) GB)" }
        Write-Host ''
        # A model that is none of the choices (set by hand in config.yaml) is offered as one more choice.
        $custom = if ($haveConfig -and $model.Index -eq 0) { $model.Text } else { '' }
        Show-Presets $r.Preset ($r.Device -eq 'cpu') $model.Index $custom
        $max = if ($custom) { $Presets.Count + 1 } else { $Presets.Count }
        $default = if ($custom) { $max } elseif ($model.Index -gt 0) { $model.Index } else { $r.Preset }
        do { $n = Read-Choice $max $default } until (Confirm-Choice $n $m)
        $p = if ($n -gt $Presets.Count) { $model.Choice } else { $Presets[$n - 1] }
        if (-not $sel -or $sel.Split) { break }
        $i = "$($sel.List[0])"
        $place = @{ Img = $i; TE = $i; Dec = $i }
        Show-SlowNote $m $i $p
        break
    }

    # Step 3b: the custom load, now that the model is known.
    if ($sel -and $sel.Split) { $place = Invoke-Split $m $p $cur }

    # Build the whole file in memory and write it last: Ctrl+C before this point leaves config.yaml as it was.
    # Other settings in config.yaml are kept.
    $source = if ($haveConfig) { 'config.yaml' } else { 'config.example.yaml' }
    try {
        $t = Set-Yaml (Read-TextFile $source) 'device' $r.Device
        $note = ''
        if ($r.Device -eq 'gpu' -and $place) {
            $g = Set-GpuConfig $t $m $place.Img $place.TE $place.Dec
            $t = $g.Text; $note = $g.Note
        }
        if ($p.Name -ne 'custom') { $t = Get-ModelText $t $p }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host 'Nothing was changed.'
        exit 1
    }
    Write-TextFile 'config.yaml' $t
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
    foreach ($d in 'models', 'outputs', 'inputs') {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path (Join-Path $Root $d) | Out-Null }
    }
    if (-not (Test-Path -LiteralPath '.env')) { Copy-Item -LiteralPath '.env.example' -Destination (Join-Path $Root '.env') }
    # server.port in config.yaml (the only "port:" key in the file)
    $port = if ($y -match '(?m)^\s+port\s*:\s*(\d+)') { [int]$Matches[1] } else { 5005 }
    # Remember the profile and port so plain `docker compose logs/restart/up` use the same settings. The file is read
    # and written as UTF-8, with its own line ends.
    $envText = Read-TextFile '.env'
    $nl = if ($envText -match "`r`n") { "`r`n" } else { "`n" }
    $keep = @(($envText -replace '(\r?\n)+\z', '') -split '\r?\n' | Where-Object { $_ -notmatch '^(COMPOSE_PROFILES|MCP_PORT)=' })
    Write-TextFile '.env' (((@($keep) + "COMPOSE_PROFILES=$prof" + "MCP_PORT=$port") -join $nl) + $nl)
    # IMAGE_REPO in .env: pull published images instead of building them here.
    $repo = if ($envText -match '(?m)^[ \t]*IMAGE_REPO[ \t]*=[ \t]*([^\s#]+)') { $Matches[1] } else { '' }
    $image = if ($repo) { "${repo}:$prof" } else { "imagegen-mcp:$prof" }
    @{ Profile = $prof; Port = $port; ImageRepo = $repo; Image = $image }
}
# True when the first install has finished: the image of the server is there (built or downloaded).
function Test-Installed {
    $s = Get-Settings
    (Invoke-Program 'docker' @('image', 'inspect', $s.Image)).Code -eq 0
}
# True when the container runs (one that keeps restarting after a crash does not count).
function Test-ServerRunning {
    $r = Invoke-Program 'docker' @('ps', '--filter', 'name=^imagegen-mcp$', '--filter', 'status=running', '--format', '{{.Names}}')
    ($r.Code -eq 0) -and [bool](($r.Out -join '').Trim())
}
# The container's Status (running, restarting, exited, ...) and Restarts, or $null when there is no container.
function Get-ContainerState {
    $r = Invoke-Program 'docker' @('inspect', '-f', '{{.State.Status}} {{.RestartCount}}', 'imagegen-mcp')
    $f = @("$(Get-FirstLine $r.Out)".Trim() -split ' ')
    if ($r.Code -ne 0 -or $f.Count -lt 2 -or $f[1] -notmatch '^[0-9]+$') { return $null }
    @{ Status = $f[0]; Restarts = [int]$f[1] }
}
# The server's answer to /api/status, or $null when it does not answer.
function Get-ServerStatus($s) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$($s.Port)/api/status" -TimeoutSec 5 -ErrorAction Stop
        $r.Content | ConvertFrom-Json
    } catch { $null }
}
# Run a program straight in this console window and return its exit code. Its output is not captured, so it can draw
# its own progress (docker compose build stops with "failed to get console" when its output goes into a pipe).
function Invoke-Console([string]$Exe, [string[]]$ArgList) {
    $path = (Get-Command $Exe -CommandType Application | Select-Object -First 1).Source
    $p = Start-Process -FilePath $path -ArgumentList $ArgList -NoNewWindow -PassThru
    $null = $p.Handle   # keeps the exit code readable after the program ends
    $p.WaitForExit()
    $p.ExitCode
}
# Step 4a. Builds the image (or pulls it with IMAGE_REPO) when it is missing, with -Force, or after an update changed
# the server code. Returns $false when that failed.
function Build-Image($s, [bool]$Force) {
    if (Test-Path -LiteralPath $BuildMark) { $Force = $true }
    $have = (Invoke-Program 'docker' @('image', 'inspect', $s.Image)).Code -eq 0
    if ($have -and -not $Force) { Write-Host '==> Using the image server you already built.'; return $true }
    if ($s.ImageRepo) {
        Write-Host "==> Downloading the image server ($($s.Image))..."
        if ((Invoke-Console 'docker' @('compose', '--profile', $s.Profile, 'pull')) -eq 0) {
            Remove-Item -LiteralPath $BuildMark -ErrorAction SilentlyContinue
            return $true
        }
        Write-Host "The download failed (details are above). Check your internet connection, then run $Launcher again." -ForegroundColor Red
        return $false
    }
    if ($have) { Write-Host '==> Building the image server again (10-30 minutes)' }
    else { Write-Host '==> Building the image server (first time only, 10-30 minutes)' }
    Write-Host "    Docker's build output follows. Leave this window open until it finishes."
    if ((Invoke-Console 'docker' @('compose', '--profile', $s.Profile, 'build')) -eq 0) {
        Remove-Item -LiteralPath $BuildMark -ErrorAction SilentlyContinue
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
# The server stopped while starting: show the end of its log (a config error is named there).
function Show-Stopped {
    Write-Host 'The server stopped while starting. The end of its log:' -ForegroundColor Red
    (Invoke-Program 'docker' @('logs', '--tail', '12', 'imagegen-mcp')).All | Where-Object { "$_".Trim() } |
        Select-Object -Last 12 | ForEach-Object { Write-Host "    $_" }
    Write-Host "If you changed config.yaml by hand, correct the setting named above or run setup.cmd. Then run $Launcher again."
    Write-Host 'Details: docker compose logs --tail 80'
}
# Steps 4b and 4c. Shows the download and the model loading until the server is ready. Returns $false on an error.
function Wait-Ready($s, $m) {
    $said = ''; $line = ''; $silent = 0; $loading = 0
    $c = Get-ContainerState
    $restarts = if ($c) { $c.Restarts } else { 0 }
    while ($true) {
        $h = Get-ServerStatus $s
        if (-not $h) {
            # No answer: the server is still starting, or its container stopped or restarted after a crash.
            $c = Get-ContainerState
            if (-not $c -or $c.Status -ne 'running' -or $c.Restarts -gt $restarts) {
                if ($line) { Write-Host '' }
                Show-Stopped
                return $false
            }
            $silent++
            if ($silent -eq 45) { Write-Host "    (still waiting for the server to answer on port $($s.Port))" }
        } else {
            $silent = 0
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
                    # Polls are 2 s apart: a note after one minute, then the minutes on one line.
                    $loading++
                    if ($loading -eq 30) {
                        Write-Host '    This can take several minutes on the first start, or on a GPU with little memory.'
                    }
                    if ($loading % 30 -eq 0) {
                        $line = "    still loading: $($loading / 30) min"
                        Write-Host -NoNewline "`r$line   "
                    }
                }
                'ready' { if ($line) { Write-Host '' }; return $true }
                'error' { if ($line) { Write-Host '' }; Show-ServerError "$($h.error)"; return $false }
            }
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
# Step 4. With 'ask', a running server is restarted only when the person wants to, or when it must be: after an
# update that changed the server, with -Build, or when it stopped with an error.
function Start-Server([string]$Mode, [bool]$Build) {
    $s = Get-Settings
    $m = Get-Machine
    if ($Mode -eq 'ask' -and (Test-ServerRunning)) {
        $h = Get-ServerStatus $s
        if (Test-Path -LiteralPath $BuildMark) { Write-Host '==> An update changed the server, so it is built again and restarted.' }
        elseif ($Build) { }
        elseif ($h -and $h.state -eq 'error') { Write-Host '==> The server stopped with an error, so it is started again.' }
        elseif (Test-Interactive) {
            Write-Host ''
            Write-Host 'The server is already running.'
            if (-not (Read-YesNo 'Restart it? (Only needed after you changed config.yaml by hand.)' $false)) {
                if (-not (Wait-Ready $s $m)) { exit 1 }
                Show-Ready $s
                return
            }
        }
    }
    if (-not (Build-Image $s $Build)) { exit 1 }
    Write-Host '==> Starting the server...'
    Invoke-Program 'docker' @('compose', '--profile', 'gpu', '--profile', 'cpu', 'down', '--remove-orphans') | Out-Null
    Invoke-Program 'docker' @('rm', '-f', 'imagegen-mcp') | Out-Null
    $r = Invoke-Program 'docker' @('compose', '--profile', $s.Profile, 'up', '-d', '--no-build')
    if ($r.Code -ne 0 -and -not (Test-ServerRunning)) { Show-UpError $s ($r.All -join "`n"); exit 1 }
    if (-not (Wait-Ready $s $m)) { exit 1 }
    Show-Ready $s
}
function Stop-Server {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Host 'Docker is not installed, so the server is not running.'; return }
    $r = Invoke-Program 'docker' @('compose', '--profile', 'gpu', '--profile', 'cpu', 'down')
    if ($r.Code -ne 0) {
        $r.All | Where-Object { "$_".Trim() } | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }
        Write-Host 'The server could not be stopped. Is Docker running?' -ForegroundColor Red
        exit 1
    }
    Write-Host 'The server is stopped. Run start.cmd to start it again.'
}

# --- update ---------------------------------------------------------------------------------------------------------
# Install the latest version with git. config.yaml, .env, the models and the images are never touched.
# A change in these paths needs a new image (see .dockerignore; docker-compose.yml has the build settings).
$ImagePaths = @('Dockerfile', 'pyproject.toml', 'src', 'docker/patches', 'docker-compose.yml', '.dockerignore')
$ImagePattern = '^(Dockerfile|pyproject\.toml|docker-compose\.yml|\.dockerignore)$|^(src|docker/patches)/'

function Invoke-Update {
    # A ZIP download has no .git folder. Check that first: git may be missing, or a stub that opens an installer.
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        Write-Host 'This folder is not a git copy (it was probably downloaded as a ZIP), so it cannot update itself.'
        Write-Host "Download the latest version from $ProjectUrl"
        Write-Host 'and copy your config.yaml, .env and models folder into it.'
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host 'Git is not installed, so this copy cannot update itself. Install Git from https://git-scm.com/downloads,'
        Write-Host "then run $Launcher again."
        return
    }
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'   # fail instead of waiting for a password
    try { Update-FromGit } finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
}
function Update-FromGit {
    $r = Invoke-Git @('rev-parse', '--show-toplevel')
    if ($r.Code -ne 0) {
        # For example "detected dubious ownership": git's next lines name the command that fixes it.
        Write-Host 'Git reported an error:'
        $r.All | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host "    $_" }
        return
    }
    if ((Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')).Code -ne 0) {
        $branch = Get-FirstLine (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Out
        if ($branch -eq 'HEAD') { Write-Host 'This copy is not on a branch, so it cannot be updated.' }
        else { Write-Host "This copy is on branch '$branch', which does not follow a branch on GitHub, so it cannot be updated." }
        return
    }
    Write-Host '==> Checking for updates...'
    $r = Invoke-Git @('fetch', '--quiet')
    if ($r.Code -ne 0) {
        Write-Host "Could not get the updates: $(Get-FirstLine $r.All)"
        Write-Host "Check your internet connection, then run $Launcher again."
        return
    }
    $behind = [int](Get-FirstLine (Invoke-Git @('rev-list', '--count', 'HEAD..@{u}')).Out)
    $diverged = [int](Get-FirstLine (Invoke-Git @('rev-list', '--count', '@{u}..HEAD')).Out)
    # Commits of this copy whose changes are not on GitHub (old commits of a rewritten GitHub history do not count).
    $ahead = [int](Get-FirstLine (Invoke-Git @('rev-list', '--count', '--cherry-pick', '--right-only', '@{u}...HEAD')).Out)
    if ($behind -eq 0) { Write-Host 'You already have the latest version.'; return }
    if ($behind -eq 1) { Write-Host '1 update is available:'; $them = 'it' } else { Write-Host "$behind updates are available:"; $them = 'them' }
    (Invoke-Git @('log', '--oneline', '--no-decorate', '--reverse', 'HEAD..@{u}')).Out | Select-Object -First 15 |
        ForEach-Object { Write-Host "    $_" }
    if ($behind -gt 15) { Write-Host "    ... and $($behind - 15) more" }
    if (-not (Read-YesNo "Install $them now?" $true)) { return }

    $old = Get-FirstLine (Invoke-Git @('rev-parse', 'HEAD')).Out
    $needBuild = $false
    $r = $null
    if ($diverged -eq 0) { $r = Invoke-Git @('merge', '--ff-only', '--quiet', '@{u}') }
    if ($diverged -ne 0 -or $r.Code -ne 0) {
        $changed = @((Invoke-Git @('status', '--porcelain', '--untracked-files=no')).Out | Where-Object { $_.Length -gt 3 } |
                     ForEach-Object { $_.Substring(3) })
        # Files of this computer where the update adds a file: git would delete them, so they are renamed first.
        $inWay = @((Invoke-Git @('diff', '--name-only', '--diff-filter=A', 'HEAD', '@{u}')).Out |
                   Where-Object { $_ -and ($changed -notcontains $_) -and (Test-Path -LiteralPath (Join-Path $Root $_)) })
        if ($ahead -eq 0 -and $changed.Count -eq 0 -and $inWay.Count -eq 0) {
            # Nothing of this computer is lost: the history on GitHub was rewritten. Take it as it is.
            Write-Host 'The version on GitHub was rewritten, so it replaces this copy.'
        } else {
            Write-Host ''
            Write-Host 'The update cannot be installed because this copy was changed on this computer:'
            $changed | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
            $inWay | Select-Object -First 15 | ForEach-Object { Write-Host "    $_ (your file, where the update adds one)" }
            if ($ahead -ne 0) { Write-Host "    $ahead commit(s) that are not on GitHub" }
            Write-Host 'Your settings (config.yaml, .env), the models and your images are not affected.'
            Write-Host ''
            Write-Host '  1) Cancel the update and keep the changes'
            Write-Host '  2) Discard the changes and install the update'
            if ((Read-Choice 2 1) -eq 1) { Write-Host 'Nothing was changed.'; return }
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $kept = @()
        # A copy for people who know git: the changed files in a stash, the old version in a branch of its own.
        # The name and email let the stash work where git has no identity set (common on new computers).
        if ($changed.Count -gt 0) {
            $st = Invoke-Git @('-c', 'user.name=Image Gen MCP', '-c', 'user.email=update@localhost', 'stash', 'push',
                               '--quiet', '-m', "changes before update $stamp")
            if ($st.Code -ne 0) {
                Write-Host "The update failed: no copy of the changes could be kept ($(Get-FirstLine $st.All))." -ForegroundColor Red
                Write-Host 'Nothing was changed.'
                exit 1
            }
            $kept += "'git stash list'"
            if (@($changed | Where-Object { $_ -match $ImagePattern }).Count -gt 0) { $needBuild = $true }
        }
        $branchName = "before-update-$stamp"
        if ((Invoke-Git @('branch', $branchName, $old)).Code -eq 0) { $kept += "the branch $branchName" }
        $moved = @()
        foreach ($f in $inWay) {
            Move-Item -LiteralPath (Join-Path $Root $f) -Destination (Join-Path $Root "$f.before-update") -Force
            $moved += "$f.before-update"
        }
        # Settings files survive even when a commit of this copy had added them to git.
        $copies = @{}
        foreach ($f in 'config.yaml', '.env', 'docker-compose.override.yml') {
            $path = Join-Path $Root $f
            if (Test-Path -LiteralPath $path) { $copies[$path] = [IO.File]::ReadAllBytes($path) }
        }
        $r = Invoke-Git @('reset', '--hard', '--quiet', '@{u}')
        foreach ($path in $copies.Keys) { if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllBytes($path, $copies[$path]) } }
        if ($r.Code -ne 0) { Write-Host "The update failed: $(Get-FirstLine $r.All)" -ForegroundColor Red; exit 1 }
        if ($kept.Count -gt 0) { Write-Host "    The old version is kept in git: $($kept -join ' and ')." }
        if ($moved.Count -gt 0) { Write-Host "    Your files were renamed: $($moved -join ', ')" }
    }
    Write-Host ''
    Write-Host '==> Update installed. Your settings in config.yaml were kept.'
    $diff = Invoke-Git (@('diff', '--name-only', $old, 'HEAD', '--') + $ImagePaths)
    if (@($diff.Out | Where-Object { "$_".Trim() }).Count -gt 0) { $needBuild = $true }
    if ($needBuild) { Set-Content -LiteralPath (Join-Path $Root $BuildMark) -Value 'an update changed the server' -Encoding ascii }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'config.yaml'))) { Write-Host 'Run start.cmd to set it up and start it.'; return }
    $start = $null
    if ($needBuild) {
        Write-Host '    The server itself changed, so it is built again (10-30 minutes) and restarted.'
        if (Read-YesNo 'Do that now?' $true) { $start = 'start' }
        else { Write-Host 'Run start.cmd when you are ready: it builds and restarts the server.' }
    } elseif (Test-ServerRunning) {
        Write-Host '    The running server does not need a restart for this update.'
    } elseif (Read-YesNo 'Start the server now?' $true) {
        $start = 'start'
    } else {
        Write-Host 'Run start.cmd to start the server.'
    }
    if ($start) {
        # A new PowerShell runs the new start script (git just replaced it).
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\imagegen.ps1') start
        exit $LASTEXITCODE
    }
}
