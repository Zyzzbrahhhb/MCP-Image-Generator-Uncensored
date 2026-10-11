# Kandinsky 6 video extension for Image Gen MCP: Kandinsky 6 Lite (4-bit OrbitQuant), text/image to video with sound.
FROM python:3.12-slim-bookworm

# git: diffusers is pinned to a commit. gcc/libc6-dev: Triton compiles a small launcher at run time.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 HF_HOME=/models/hf HF_HUB_DISABLE_TELEMETRY=1

# Versions from the OrbitQuant model card (tested there on an RTX 3090; here on RTX 3080, 3080 Ti and 5090).
RUN pip install torch==2.12.1 torchvision==0.27.1 --index-url https://download.pytorch.org/whl/cu130
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

# A named non-root user: PyTorch looks up the user name for its cache folders.
RUN useradd --uid 1000 --create-home imagegen
USER imagegen

WORKDIR /app
COPY video_ext /app/video_ext
ENTRYPOINT ["python", "-m", "video_ext"]
CMD ["serve"]
