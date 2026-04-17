# 🎛️ DJ Pipelinez (Host Mode)

Automated AI video upscaling pipeline using **Real-ESRGAN + ffmpeg (NVENC)** — now running **natively on the host** for maximum GPU compatibility and minimal runtime headaches.

Drop clips into a folder (via SMB or local), and they’ll be automatically:

* processed
* AI upscaled
* exported as **true 4K (3840×2160)**
* with original audio preserved

---

## 🧠 Why Host Mode?

After testing Docker-based GPU/Vulkan pipelines, it turned out:

> GPU/Vulkan + containers = more plumbing than value (for this use case)

So this version runs **directly on Leviathan**, which gives:

* ✅ reliable Vulkan + NVIDIA access
* ✅ no container runtime quirks
* ✅ easier debugging
* ✅ same workflow, fewer moving parts

---

## 📁 Directory Layout

```text
/mnt/leviathan/data/upscale/
├── incoming/   # drop files here (SMB target)
├── originals/  # claimed source files retained here
├── outgoing/   # finished clips
├── failed/     # failed jobs
└── work/       # temp processing
```

---

## 🚀 Quick Start

### 1. Install dependencies (host)

```bash
sudo apt update
sudo apt install ffmpeg inotify-tools
```

Ensure NVIDIA drivers are working:

```bash
nvidia-smi
```

Optional (for sanity checks):

```bash
sudo apt install vulkan-tools libvulkan1
vulkaninfo | grep deviceName
```

---

### 2. Install Real-ESRGAN

Download and extract:

```bash
cd /opt
wget https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip
unzip realesrgan-ncnn-vulkan-20220424-ubuntu.zip
```

Binary path:

```text
/opt/realesrgan-ncnn-vulkan-20220424-ubuntu/realesrgan-ncnn-vulkan
```

---

### 3. Place scripts

Put these in:

```text
/srv/dj-pipelinez/
```

Files:

* `watch.sh`
* `process.sh`

Make executable:

```bash
chmod +x /srv/dj-pipelinez/*.sh
```

---

### 4. Run watcher

```bash
/srv/dj-pipelinez/watch.sh
```

---

### 5. Drop a clip

Via SMB:

```text
\\leviathan\upscale-incoming
```

Or locally:

```bash
cp video.mp4 /mnt/leviathan/data/upscale/incoming/
```

---

### 6. Profit

Output appears in:

```text
/mnt/leviathan/data/upscale/outgoing/
```

Claimed source files are moved out of `incoming/` into:

```text
/mnt/leviathan/data/upscale/originals/
```

If an input basename or rendered output name already exists, the pipeline appends a numeric suffix instead of overwriting the older file.

---

## 🎬 Pipeline

1. Move the source clip into `originals/` so it is not queued twice
2. Extract frames with ffmpeg
3. Upscale frames via Real-ESRGAN (GPU/Vulkan)
4. Reassemble video
5. Preserve original audio
6. Scale/pad to 3840×2160
7. Encode using **NVENC (GPU)**

---

## ⚙️ Key Settings

Inside `process.sh`:

| Setting               | Description                           |
| --------------------- | ------------------------------------- |
| `MODEL_NAME`          | AI model (default: realesrgan-x4plus) |
| `TILE_SIZE`           | VRAM tiling                           |
| `TARGET_WIDTH/HEIGHT` | 3840×2160                             |
| `CQ`                  | NVENC quality (18 default)            |
| `PRESET`              | NVENC speed (p5 default)              |

---

## 🧪 GPU Acceleration

This pipeline uses GPU for:

* 🔥 AI upscaling (Vulkan)
* ⚡ video encoding (NVENC)

Verify:

```bash
watch -n1 nvidia-smi
```

You should see:

* spike during upscale
* spike during encode

---

## ⚠️ Notes

* Frame-based → temporary disk usage can spike
* Large clips = longer processing time
* Output is always forced to **true 4K**
* Aspect ratio preserved with padding

---

## 🔧 Optional: systemd service

Create:

```bash
/etc/systemd/system/dj-pipelinez.service
```

```ini
[Unit]
Description=DJ Pipelinez Watcher
After=network.target

[Service]
ExecStart=/srv/dj-pipelinez/watch.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
sudo systemctl daemon-reexec
sudo systemctl enable dj-pipelinez
sudo systemctl start dj-pipelinez
```

---

## 🎛️ Philosophy

> Use AI for power, not authorship.

DJ Pipelinez:

* automates the boring parts
* keeps creative control in your hands
* stays simple enough to actually maintain

---

## 😄 Credits

Built by:

* DJ Pipelinez
* Chat (Umaro Mode)

---

## 📜 License

Do whatever you want, just don’t blame Leviathan if it starts breathing fire.
