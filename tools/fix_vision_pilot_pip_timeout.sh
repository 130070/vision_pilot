#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="${1:-$HOME/vision_pilot}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
DOCKERFILE="$REPO_DIR/VisionPilot/docker/Dockerfile"

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
pattern = re.compile(r'RUN pip3 install[^\n]*(?:\\\n[ \t]*[^\n]*)*opencv-python numpy')
new = f'''RUN pip3 install -i {index_url} \\
        --trusted-host {host} \\
        --timeout 120 --retries 10 \\
        --no-cache-dir --break-system-packages \\
        opencv-python numpy'''
text = path.read_text()
updated, count = pattern.subn(new, text, count=1)
if count:
    path.write_text(updated)
    print(f'Patched {path}')
elif index_url in text and 'opencv-python numpy' in text:
    print(f'{path} already uses {index_url}')
else:
    raise SystemExit('target pip install line not found; inspect with: grep -n "pip3 install" Dockerfile')
PY

cd "$REPO_DIR/VisionPilot/docker"
chmod +x build.sh
if docker info >/dev/null 2>&1; then
  ./build.sh --gpu
else
  sudo ./build.sh --gpu
fi
