#!/usr/bin/env bash
set -Eeuo pipefail

# Patch VisionPilot's GPU Dockerfile for slower networks and resume the build.
# Usage:
#   bash fix_vision_pilot_gpu_build_network.sh [repo_dir]
# Optional env:
#   PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
#   ONNXRUNTIME_URL=https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/onnxruntime-linux-x64-gpu_cuda13-1.26.0.tgz

REPO_DIR="${1:-$HOME/vision_pilot}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
DOCKER_DIR="$REPO_DIR/VisionPilot/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Dockerfile not found: $DOCKERFILE" >&2
  exit 1
fi

python3 - "$DOCKERFILE" "$PIP_INDEX_URL" <<'PY'
from pathlib import Path
from urllib.parse import urlparse
import re
import sys

path = Path(sys.argv[1])
index_url = sys.argv[2].rstrip('/')
host = urlparse(index_url).hostname or 'pypi.tuna.tsinghua.edu.cn'
text = path.read_text()

pip_pattern = re.compile(r'RUN pip3 install[^\n]*(?:\\\n[ \t]*[^\n]*)*opencv-python numpy')
pip_replacement = f'''RUN pip3 install -i {index_url} \\
        --trusted-host {host} \\
        --timeout 120 --retries 10 \\
        --no-cache-dir --break-system-packages \\
        opencv-python numpy'''
text, pip_count = pip_pattern.subn(pip_replacement, text, count=1)

if 'ARG ONNXRUNTIME_URL' not in text:
    text = text.replace('ARG ONNXRUNTIME_VERSION=1.26.0\n', 'ARG ONNXRUNTIME_VERSION=1.26.0\nARG ONNXRUNTIME_URL=\n', 1)
    text = text.replace('ARG ONNXRUNTIME_VERSION\n', 'ARG ONNXRUNTIME_VERSION\nARG ONNXRUNTIME_URL\n', 1)

onnx_pattern = re.compile(
    r'wget\s+(?:-[^\n]*\s+)*-O\s+ort\.tgz\s+"https://github\.com/microsoft/onnxruntime/releases/download/v\$\{ONNXRUNTIME_VERSION\}/onnxruntime-linux-x64-gpu_cuda13-\$\{ONNXRUNTIME_VERSION\}\.tgz"'
)
onnx_replacement = 'wget --tries=20 --timeout=60 --read-timeout=60 --progress=dot:giga -O ort.tgz "${ONNXRUNTIME_URL:-https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-linux-x64-gpu_cuda13-${ONNXRUNTIME_VERSION}.tgz}"'
text, onnx_count = onnx_pattern.subn(onnx_replacement, text, count=1)

path.write_text(text)
print(f'Patched pip install: {bool(pip_count)}')
print(f'Patched ONNX Runtime download: {bool(onnx_count)}')
PY

cd "$DOCKER_DIR"
chmod +x build.sh

# Do not pass 127.0.0.1 proxy args unless a proxy is really running on the server.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

if docker info >/dev/null 2>&1; then
  ./build.sh --gpu
else
  sudo env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY ./build.sh --gpu
fi
