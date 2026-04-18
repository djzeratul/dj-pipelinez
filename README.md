# DJ Pipelinez

Automated AI video upscaling pipeline using Real-ESRGAN and ffmpeg with NVENC.

This repo now keeps both platform variants side by side:

```text
scripts/
├── linux/
│   ├── watch.sh
│   └── process.sh
└── windows/
    ├── watch.ps1
    └── process.ps1
```

`scripts/linux/` is the original Linux host workflow.

`scripts/windows/` is the native PowerShell port for Windows.

## What The Pipeline Does

Both variants follow the same basic flow:

1. Watch an `incoming` directory
2. Wait until the copied file appears stable
3. Move the source clip out of the queue so it is not processed twice
4. Extract frames with ffmpeg
5. Upscale frames with Real-ESRGAN
6. Reassemble the final video as 3840x2160
7. Preserve original audio when present

## Linux

Linux scripts live in `scripts/linux/watch.sh` and `scripts/linux/process.sh`.

They keep the original host-oriented assumptions:

- queue root under `/mnt/leviathan/data/upscale/`
- Real-ESRGAN under `/opt/realesrgan-ncnn-vulkan`
- deployed runtime script path `/srv/dj-pipelinez/scripts/linux/process.sh`
- file watching via `inotifywait`
- single-worker locking via `flock`

Typical deployment looks like this:

```bash
sudo apt update
sudo apt install ffmpeg inotify-tools
```

Copy the Linux scripts to `/srv/dj-pipelinez/scripts/linux/`, make them executable, and run:

```bash
/srv/dj-pipelinez/scripts/linux/watch.sh
```

### Linux `systemd` Update

If you already had a service pointing at the old root-level script, update `ExecStart` to the new deployed path.

Example unit:

```ini
[Unit]
Description=DJ Pipelinez Watcher
After=network.target

[Service]
ExecStart=/srv/dj-pipelinez/scripts/linux/watch.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

After editing the service:

```bash
sudo systemctl daemon-reload
sudo systemctl restart dj-pipelinez
```

## Windows

Windows scripts live in `scripts/windows/watch.ps1` and `scripts/windows/process.ps1`.

### Windows Dependencies

You need:

1. NVIDIA drivers with NVENC support
2. `ffmpeg.exe` and `ffprobe.exe`
3. `realesrgan-ncnn-vulkan.exe`
4. PowerShell 7 (`pwsh`) recommended

Sanity checks:

```powershell
nvidia-smi
ffmpeg -hide_banner -encoders | Select-String hevc_nvenc
```

### Wiring Dependencies on Windows

The scripts support either `PATH`-based discovery or explicit environment variables.

If the tools are on `PATH`, these should resolve:

```powershell
ffmpeg
ffprobe
realesrgan-ncnn-vulkan
```

If you prefer explicit paths:

```powershell
$env:FFMPEG_EXE = "C:\Tools\ffmpeg\bin\ffmpeg.exe"
$env:FFPROBE_EXE = "C:\Tools\ffmpeg\bin\ffprobe.exe"
$env:DJ_PIPELINEZ_REALSR_EXE = "C:\Tools\realesrgan-ncnn-vulkan\realesrgan-ncnn-vulkan.exe"
$env:DJ_PIPELINEZ_DATA_ROOT = "D:\dj-pipelinez"
```

Persist them if you want:

```powershell
setx FFMPEG_EXE "C:\Tools\ffmpeg\bin\ffmpeg.exe"
setx FFPROBE_EXE "C:\Tools\ffmpeg\bin\ffprobe.exe"
setx DJ_PIPELINEZ_REALSR_EXE "C:\Tools\realesrgan-ncnn-vulkan\realesrgan-ncnn-vulkan.exe"
setx DJ_PIPELINEZ_DATA_ROOT "D:\dj-pipelinez"
```

Open a new terminal after `setx`.

### Windows Defaults

If `DJ_PIPELINEZ_DATA_ROOT` is not set, the Windows scripts use:

```text
state\upscale\
├── incoming\
├── originals\
├── outgoing\
├── failed\
└── work\
```

relative to the repo root.

### Run The Windows Watcher

From the repo root:

```powershell
pwsh -NoProfile -File .\scripts\windows\watch.ps1
```

Example input copy:

```powershell
Copy-Item "C:\clips\video.mp4" ".\state\upscale\incoming\"
```

If `DJ_PIPELINEZ_DATA_ROOT` is set, use that root's `incoming` directory instead.

### Windows Tunables

`scripts/windows/process.ps1` reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DJ_PIPELINEZ_MODEL_NAME` | `realesrgan-x4plus` | Real-ESRGAN model name |
| `DJ_PIPELINEZ_TILE_SIZE` | `256` | Tile size for VRAM pressure |
| `DJ_PIPELINEZ_THREADS` | `1:1:1` | Real-ESRGAN thread tuple |
| `DJ_PIPELINEZ_CQ` | `18` | NVENC constant quality |
| `DJ_PIPELINEZ_PRESET` | `p5` | NVENC preset |
| `DJ_PIPELINEZ_TARGET_WIDTH` | `3840` | Final output width |
| `DJ_PIPELINEZ_TARGET_HEIGHT` | `2160` | Final output height |
| `DJ_PIPELINEZ_WATCH_DIR` | `<data root>\incoming` | Override only the watched folder |

## Notes

- Linux and Windows now live side by side without changing the Linux runtime behavior.
- The Windows watcher uses `FileSystemWatcher` plus a size stability check.
- The Windows processor uses a named mutex so only one clip is processed at a time.
- Output remains padded or scaled to true 4K while preserving aspect ratio.
