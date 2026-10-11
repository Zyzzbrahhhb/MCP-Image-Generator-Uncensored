# The video extension's setup questions (Windows), dot-sourced by scripts\extensions.ps1 after the image settings are
# saved. The same rules as setup.sh: see the table there and docs/kandinsky6.md.

function Invoke-ExtSetup-kandinsky6($m) {
    $cfg = Read-TextFile 'config.yaml'
    $used = @()
    $device = if ($cfg -match '(?m)^device[ \t]*:[ \t]*"?([A-Za-z]+)') { $Matches[1].ToLower() } else { 'gpu' }
    if ($device -ne 'cpu') {
        $used = @(((Get-YamlValue $cfg 'gpu' 'diffusion') -replace '[\[\] ]', '') -split ',') +
                @(Get-YamlValue $cfg 'gpu' 'text_encoder') + @(Get-YamlValue $cfg 'gpu' 'vae') |
                Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique
    }
    $split = @(((Get-YamlValue $cfg 'gpu' 'diffusion') -replace '[\[\] ]', '') -split ',' | Where-Object { $_ }).Count -gt 1
    # Default: the largest GPU (8 GB or more) the image model does not use; otherwise the largest GPU.
    $byGb = @($m.Gpus | Sort-Object -Property @{ Expression = 'GB'; Descending = $true }, Index)
    $def = @($byGb | Where-Object { $_.GB -ge 8 -and $used -notcontains $_.Index })[0]
    if (-not $def) { $def = $byGb[0] }
    $gpu = $def
    if ($m.GpuCount -gt 1) {
        Write-Host ''
        Write-Host 'Which GPU should the video use?'
        $n = 0; $choice = 1
        foreach ($g in $m.Gpus) {
            $n++
            $note = if ($used -contains $g.Index) { ' (the image model uses it)' } else { '' }
            Write-Host "  $n) GPU $($g.Index): $($g.Name), $($g.GB) GB$note"
            if ($g.Index -eq $def.Index) { $choice = $n }
        }
        $gpu = $m.Gpus[(Read-Choice $n $choice) - 1]
    }
    $gb = [int]$gpu.GB
    if ($gb -lt 8) {
        Write-Host "The video needs a GPU with 8 GB or more; GPU $($gpu.Index) has $gb GB. The extension is not installed."
        return $false
    }
    $uuid = ''
    $r = Invoke-Program 'nvidia-smi' @('--query-gpu=index,uuid', '--format=csv,noheader')
    foreach ($line in $r.Out) {
        $f = "$line" -split ','
        if ($f.Count -ge 2 -and $f[0].Trim() -eq "$($gpu.Index)") { $uuid = $f[1].Trim() }
    }
    $shared = $used -contains $gpu.Index
    $mode = 'stream'; $cap = ''; $limit = 0; $mem = '20g'
    if ($shared) {
        if ($gb -ge 24) { $mode = 'fast'; $limit = $gb - 13 }
        elseif ($gb -ge 13) { $limit = $gb - 7 }
        else { $limit = [math]::Max(2, $gb - 6) }
        if ($split) { Write-Host 'Note: the image model is split across GPUs, so its memory limits are left as they are.' }
        else { Write-TextFile 'config.yaml' (Set-Yaml (Read-TextFile 'config.yaml') 'max_vram_gb' "{$($gpu.Index): $limit}" 'gpu') }
    } else {
        if ($gb -ge 20) { $mode = 'resident'; $mem = '12g' }
        elseif ($gb -ge 14) { $mode = 'fast' }
        elseif ($gb -ge 10) { $mode = 'low-memory'; $cap = ('{0:0.0}' -f ($gb - $(if ($gb -ge 12) { 2.5 } else { 1.5 }))).Replace(',', '.') }
    }
    $env = @(
        '# Written by the setup (run it again to change). See .env.example.'
        "VIDEO_GPU=$(if ($uuid) { $uuid } else { $gpu.Index })"
        "VIDEO_MODE=$mode"
        "VIDEO_CAP_GB=$cap"
        "VIDEO_MEM_LIMIT=$mem"
        'VIDEO_IDLE_UNLOAD_SECONDS=600'
        "SHARES_IMAGE_GPU=$(if ($shared) { 'yes' } else { 'no' })"
        "GPU_GB=$gb"
    ) -join "`n"
    Write-TextFile 'extensions\kandinsky6\.env' "$env`n"
    Write-Host ''
    Write-Host "==> Video: GPU $($gpu.Index) ($gb GB), mode $mode."
    if ($shared -and $gb -le 12) {
        Write-Host '    It shares this GPU with the image model: one job runs at a time (a video waits for an image and the'
        Write-Host "    other way round), and the image model is limited to $limit GB. About 2.5 minutes per 5 s of video."
    } elseif ($shared) {
        Write-Host "    It shares this GPU with the image model; both can run at once (image model limited to $limit GB)."
    }
    # Measured peaks: the image server 6-15 GB, the video 7 GB (resident) or 13-16 GB (the other modes).
    $need = if ($mode -eq 'resident') { 22 } else { 31 }
    if ($m.DockerGB -gt 0 -and $m.DockerGB -lt $need) {
        Write-Host "    Warning: Docker can use $($m.DockerGB) GB of memory. The image server and the video together need up to"
        Write-Host "    about $need GB. See docs/kandinsky6.md."
    }
    return $true
}
