#!/usr/bin/env bash
set -Eeuo pipefail

# Configure an Ubuntu server for Autoware VisionPilot with the project Docker flow.
# Run on the target server as the normal user, for example:
#   bash setup_vision_pilot_server.sh --variant auto

REPO_URL="https://github.com/autowarefoundation/vision_pilot.git"
REPO_DIR="$HOME/vision_pilot"
REF="main"
VARIANT="auto"
ROS2="false"
INSTALL_DOCKER="auto"
INSTALL_NVIDIA_TOOLKIT="auto"
SKIP_BUILD="false"

usage() {
  cat <<'USAGE'
Usage: bash setup_vision_pilot_server.sh [options]

Options:
  --repo-dir DIR              Clone/update repo here (default: $HOME/vision_pilot)
  --ref REF                   Git ref to checkout (default: main; e.g. v1.0)
  --variant auto|cpu|gpu      Build variant (default: auto; gpu if nvidia-smi exists)
  --ros2                      Build ROS 2 image/config
  --install-docker            Install Docker if missing (default: auto)
  --no-install-docker         Do not install Docker; fail if missing
  --install-nvidia-toolkit    Install NVIDIA Container Toolkit for GPU variant (default: auto)
  --no-install-nvidia-toolkit Do not install NVIDIA Container Toolkit
  --skip-build                Clone/configure only; do not build image
  -h, --help                  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      REPO_DIR="${2:?Missing value for --repo-dir}"
      shift 2
      ;;
    --ref)
      REF="${2:?Missing value for --ref}"
      shift 2
      ;;
    --variant)
      VARIANT="${2:?Missing value for --variant}"
      shift 2
      ;;
    --ros2)
      ROS2="true"
      shift
      ;;
    --install-docker)
      INSTALL_DOCKER="yes"
      shift
      ;;
    --no-install-docker)
      INSTALL_DOCKER="no"
      shift
      ;;
    --install-nvidia-toolkit)
      INSTALL_NVIDIA_TOOLKIT="yes"
      shift
      ;;
    --no-install-nvidia-toolkit)
      INSTALL_NVIDIA_TOOLKIT="no"
      shift
      ;;
    --skip-build)
      SKIP_BUILD="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$VARIANT" != "auto" && "$VARIANT" != "cpu" && "$VARIANT" != "gpu" ]]; then
  echo "--variant must be one of: auto, cpu, gpu" >&2
  exit 2
fi

LOG_FILE="$HOME/vision_pilot_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR: setup failed at line $LINENO. See log: $LOG_FILE" >&2' ERR

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This setup script is intended for Linux servers." >&2
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required when running as a non-root user." >&2
    exit 1
  fi
  SUDO=(sudo)
fi

apt_install() {
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

need_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script currently supports apt-based Ubuntu hosts." >&2
    exit 1
  fi
}

ensure_base_packages() {
  need_apt
  "${SUDO[@]}" apt-get update
  apt_install ca-certificates curl gnupg git lsb-release python3
}

install_docker_engine() {
  need_apt
  echo "Installing Docker Engine from Docker's Ubuntu apt repository..."
  "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | "${SUDO[@]}" gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  "${SUDO[@]}" chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Automatic Docker install is only wired for Ubuntu. Install Docker manually or rerun with --no-install-docker." >&2
    exit 1
  fi
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ -z "$codename" ]]; then
    echo "Could not determine Ubuntu codename from /etc/os-release." >&2
    exit 1
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null
  "${SUDO[@]}" apt-get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  "${SUDO[@]}" systemctl enable --now docker
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed: $(docker --version || true)"
    return
  fi

  if [[ "$INSTALL_DOCKER" == "no" ]]; then
    echo "Docker is not installed and --no-install-docker was set." >&2
    exit 1
  fi

  install_docker_engine
}

docker_prefix() {
  if docker info >/dev/null 2>&1; then
    printf '%s\n' ""
  else
    printf '%s\n' "sudo"
  fi
}

install_nvidia_toolkit() {
  need_apt
  echo "Installing NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | "${SUDO[@]}" gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  "${SUDO[@]}" apt-get update
  apt_install nvidia-container-toolkit
  "${SUDO[@]}" nvidia-ctk runtime configure --runtime=docker
  "${SUDO[@]}" systemctl restart docker
}

ensure_nvidia_toolkit_if_needed() {
  if [[ "$VARIANT" != "gpu" ]]; then
    return
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "GPU variant was requested, but nvidia-smi was not found. Install NVIDIA drivers or use --variant cpu." >&2
    exit 1
  fi

  if command -v nvidia-ctk >/dev/null 2>&1; then
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
      echo "Docker NVIDIA runtime appears to be configured."
      return
    fi
    if sudo docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
      echo "Docker NVIDIA runtime appears to be configured."
      return
    fi
  fi

  if [[ "$INSTALL_NVIDIA_TOOLKIT" == "no" ]]; then
    echo "Docker GPU runtime is not working and --no-install-nvidia-toolkit was set." >&2
    exit 1
  fi

  install_nvidia_toolkit
}

choose_variant() {
  if [[ "$VARIANT" == "auto" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      VARIANT="gpu"
    else
      VARIANT="cpu"
    fi
  fi
  echo "Selected build variant: $VARIANT"
}

clone_or_update_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    echo "Updating existing repository: $REPO_DIR"
    git -C "$REPO_DIR" fetch --tags --prune origin
  elif [[ -e "$REPO_DIR" ]]; then
    echo "Target path exists but is not a Git repo: $REPO_DIR" >&2
    exit 1
  else
    echo "Cloning $REPO_URL into $REPO_DIR"
    git clone --recursive "$REPO_URL" "$REPO_DIR"
  fi

  git -C "$REPO_DIR" checkout "$REF"
  git -C "$REPO_DIR" submodule update --init --recursive
  echo "Repository ready at $(git -C "$REPO_DIR" rev-parse --short HEAD) on ref $REF"
}

set_conf_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" "$value" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text()
pattern = re.compile(rf"^(\s*{re.escape(key)}\s*=\s*).*$", re.MULTILINE)
replacement = rf"\g<1>{value}"
if pattern.search(text):
    text = pattern.sub(replacement, text, count=1)
elif text.endswith("\n"):
    text += f"{key} = {value}\n"
else:
    text += f"\n{key} = {value}\n"
path.write_text(text)
PY
}

configure_project() {
  local config_dir="$REPO_DIR/VisionPilot/config"
  local provider="$VARIANT"
  local source_mode="video"
  if [[ "$ROS2" == "true" ]]; then
    source_mode="ros2"
  fi

  echo "Configuring VisionPilot provider=$provider source.mode=$source_mode"
  set_conf_key "$config_dir/vision_pilot.conf" "engine.provider" "$provider"
  set_conf_key "$config_dir/vision_pilot_test.conf" "engine.provider" "$provider"
  set_conf_key "$config_dir/vision_pilot.conf" "source.mode" "$source_mode"
  set_conf_key "$config_dir/vision_pilot_test.conf" "source.mode" "$source_mode"
}

run_build() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    echo "Skipping Docker build because --skip-build was set."
    return
  fi

  local docker_dir="$REPO_DIR/VisionPilot/docker"
  if [[ ! -d "$docker_dir" ]]; then
    echo "Docker directory not found: $docker_dir" >&2
    exit 1
  fi

  chmod +x "$docker_dir"/build.sh "$docker_dir"/run.sh 2>/dev/null || true

  local args=()
  if [[ "$VARIANT" == "cpu" ]]; then
    args+=(--cpu)
  else
    args+=(--gpu)
  fi
  if [[ "$ROS2" == "true" ]]; then
    args+=(--ros2)
  fi

  echo "Running Docker build: ./build.sh ${args[*]}"
  cd "$docker_dir"
  local dp
  dp="$(docker_prefix)"
  if [[ -z "$dp" ]]; then
    ./build.sh "${args[@]}"
  else
    sudo ./build.sh "${args[@]}"
  fi
}

verify_setup() {
  local dp
  dp="$(docker_prefix)"
  echo "Docker images matching VisionPilot:"
  if [[ -z "$dp" ]]; then
    docker images | grep -Ei 'vision|pilot|autoware' || true
  else
    sudo docker images | grep -Ei 'vision|pilot|autoware' || true
  fi

  cat <<EOF

Setup finished.
Repo:       $REPO_DIR
Ref:        $REF
Variant:    $VARIANT
ROS 2:      $ROS2
Log:        $LOG_FILE

Useful next commands on the server:
  cd "$REPO_DIR/VisionPilot/docker"
  ./run.sh --$VARIANT

If Docker says permission denied, either run the command with sudo:
  sudo ./run.sh --$VARIANT

or log out/in after adding your user to the docker group:
  sudo usermod -aG docker "$USER"
EOF
}

main() {
  echo "VisionPilot setup started at $(date -Is)"
  ensure_base_packages
  ensure_docker
  choose_variant
  ensure_nvidia_toolkit_if_needed
  clone_or_update_repo
  configure_project
  run_build
  verify_setup
}

main "$@"
