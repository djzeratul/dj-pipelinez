FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    ffmpeg \
    inotify-tools \
    jq \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Real-ESRGAN ncnn Vulkan binary
RUN curl -L -o /tmp/realesrgan.zip \
      https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip \
    && unzip /tmp/realesrgan.zip -d /opt/realesrgan \
    && rm /tmp/realesrgan.zip \
    && chmod +x /opt/realesrgan/realesrgan-ncnn-vulkan

COPY watch.sh /usr/local/bin/watch.sh
COPY process.sh /usr/local/bin/process.sh

RUN chmod +x /usr/local/bin/watch.sh /usr/local/bin/process.sh

ENTRYPOINT ["/usr/local/bin/watch.sh"]
