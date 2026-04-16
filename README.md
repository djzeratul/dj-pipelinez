# 🎛️ DJ Pipelinez

Automated AI video upscaling pipeline using Real-ESRGAN + Docker.

Drop low-res clips into a folder (via SMB or otherwise), and they'll be automatically:

* processed
* upscaled to 4K (3840x2160)
* exported with original audio preserved

---

## 🧠 Overview

DJ Pipelinez is a **watch-folder based video processing worker**:

```
incoming/ → [watcher] → [upscale pipeline] → outgoing/
```

---

## ✨ Features

* 📂 Watch-folder automation (no manual triggering)
* ⚡ GPU-accelerated upscaling (Real-ESRGAN ncnn Vulkan)
* 🎬 Frame-based processing pipeline
* 🔊 Preserves original audio
* 📺 Outputs true UHD (3840×2160)
* 🧱 Dockerized for portability
* 📁 SMB-friendly workflow (drop files from Windows)

---

## 📁 Directory Structure

Host paths (recommended):

```
/mnt/leviathan/upscale/
├── incoming/   # drop files here
├── outgoing/   # finished clips
├── failed/     # failed jobs
└── work/       # temp processing
```

---

## 🚀 Quick Start

### 1. Clone repo

```bash
git clone <your-repo>
cd dj-pipelinez
```

### 2. Build container

```bash
docker compose build
```

### 3. Start worker

```bash
docker compose up -d
```

### 4. Drop a clip

Copy a file into:

```
/mnt/leviathan/upscale/incoming/
```

or via SMB:

```
\\leviathan\upscale-incoming
```

### 5. Profit

Upscaled video appears in:

```
/mnt/leviathan/upscale/outgoing/
```

---

## ⚙️ Configuration

Set via `docker-compose.yml`:

| Variable      | Description       | Default           |
| ------------- | ----------------- | ----------------- |
| MODEL_NAME    | Real-ESRGAN model | realesrgan-x4plus |
| TILE_SIZE     | VRAM tiling size  | 512               |
| TARGET_WIDTH  | Output width      | 3840              |
| TARGET_HEIGHT | Output height     | 2160              |
| CRF           | Video quality     | 17                |
| PRESET        | Encoding speed    | slow              |

---

## 🎬 Pipeline Breakdown

1. Extract frames with ffmpeg
2. Upscale frames via Real-ESRGAN
3. Reassemble video
4. Preserve original audio
5. Scale/pad to exact 3840×2160
6. Encode final output

---

## 🧪 GPU Support

Requires:

* NVIDIA GPU
* NVIDIA drivers installed on host
* NVIDIA Container Toolkit

Verify with:

```bash
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

---

## 📦 Real-ESRGAN Binary

This project uses:

```
realesrgan-ncnn-vulkan-v0.2.0-ubuntu
```

Download source:
https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan/releases

Binary path inside container:

```
/opt/realesrgan/realesrgan-ncnn-vulkan-v0.2.0-ubuntu/realesrgan-ncnn-vulkan
```

---

## ⚠️ Notes

* Processing is frame-based → disk usage spikes during jobs
* Large clips will take time depending on GPU
* Output is always forced to UHD resolution
* Aspect ratio is preserved with padding if needed

---

## 🔧 Future Improvements

* [ ] NVENC encoding (h264_nvenc / hevc_nvenc)
* [ ] Job queue + concurrency control
* [ ] Web UI / dashboard
* [ ] ntfy / webhook notifications
* [ ] Multi-node scaling (👀 Leviathan cluster)

---

## 🎛️ Philosophy

> Use AI for power, not authorship.

DJ Pipelinez is designed to:

* automate the boring parts
* preserve creative control
* keep you in the director’s chair

---

## 😄 Credits

Built by:

* DJ
* Umaro

---

## 📜 License

Do whatever you want, just don’t blame me if you melt your GPU.
