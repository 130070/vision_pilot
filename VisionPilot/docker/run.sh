#!/usr/bin/env bash
#
# Run the VisionPilot Docker container — GPU or CPU variant (default: GPU).
#
#
# Usage:
#   ./run.sh [--gpu|--cpu] [--ros2] [--v4l2 <host_device>[:<container_device>]] [--data <host_dir>[:<container_dir>]] [--output-video <host_mp4>] [--output-csv <host_csv>] [--no-display] [--no-xhost]
#
# Examples:
#   ./run.sh                                  # GPU build, no test data/display
#   ./run.sh --cpu                            # CPU build
#   ./run.sh --v4l2 /dev/video0:/dev/video0   # CPU build
#   ./run.sh --data /data                     # same path in container
#   ./run.sh --data /host/data:/data          # mounted at a different path
#   ./run.sh --gpu --ros2                     # matches the -ros2 tag suffix from build.sh
#
# Anything after a literal `--` is passed through as extra arguments to
# VisionPilot itself:
#   ./run.sh --cpu -- --some-app-flag value

set -euo pipefail

VARIANT="gpu"
V4L2=""
ENABLE_ROS2="OFF"
TAG=""
DATA_DIR=""
NO_DISPLAY=""
NO_XHOST=""
OUTPUT_VIDEO=""
OUTPUT_CSV=""

usage() {
    awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gpu)
            VARIANT="gpu"
            shift
            ;;
        --cpu)
            VARIANT="cpu"
            shift
            ;;
        --v4l2)
            [ $# -ge 2 ] || { echo "Error: --v4l2 requires a value" >&2; exit 1; }
            V4L2="$2"
            shift 2
            ;;
        --ros2)
            ENABLE_ROS2="ON"
            shift
            ;;
        --no-ros2)
            ENABLE_ROS2="OFF"
            shift
            ;;
        --data)
            [ $# -ge 2 ] || { echo "Error: --data requires a value" >&2; exit 1; }
            DATA_DIR="$2"
            shift 2
            ;;
        --output-video)
            [ $# -ge 2 ] || { echo "Error: --output-video requires a value" >&2; exit 1; }
            OUTPUT_VIDEO="$2"
            shift 2
            ;;
        --output-csv)
            [ $# -ge 2 ] || { echo "Error: --output-csv requires a value" >&2; exit 1; }
            OUTPUT_CSV="$2"
            shift 2
            ;;
        --no-display)
            NO_DISPLAY="1"
            shift
            ;;
        --no-xhost)
            NO_XHOST="1"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            usage
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not on PATH." >&2
    exit 1
fi

# Default tag matches build.sh's naming convention
TAG="visionpilot:${VARIANT}"
if [ "$ENABLE_ROS2" = "ON" ]; then
    TAG="${TAG}-ros2"
fi


if ! docker image inspect "$TAG" >/dev/null 2>&1; then
    echo "Error: image '$TAG' not found locally." >&2
    echo "Build it first, e.g.: ./build.sh --${VARIANT}$( [ "$ENABLE_ROS2" = "ON" ] && echo " --ros2" )" >&2
    exit 1
fi

if [ ! -d "../config" ]; then
    echo "Error: ../config directory not found." >&2
    exit 1
fi
CONFIG_DIR="$(cd ../config && pwd)"

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

DOCKER_ARGS=(--rm -it)

if [ "$VARIANT" = "gpu" ]; then
    DOCKER_ARGS+=(--gpus all)
fi

if [ "$ENABLE_ROS2" = "ON" ]; then
    DOCKER_ARGS+=(--network host)
fi

if [ -n "$DATA_DIR" ]; then
    if [[ "$DATA_DIR" == *:* ]]; then
        DATA_HOST_PATH="${DATA_DIR%%:*}"
        DATA_CONTAINER_PATH="${DATA_DIR#*:}"
    else
        DATA_HOST_PATH="$DATA_DIR"
        DATA_CONTAINER_PATH="$DATA_DIR"
    fi
    if [ ! -e "$DATA_HOST_PATH" ]; then
        echo "Error: --data host path '$DATA_HOST_PATH' does not exist." >&2
        exit 1
    fi
    # Resolve to an absolute path for the same reason as --dev-config below —
    # Docker's -v silently does the wrong thing with a relative host path.
    DATA_HOST_PATH="$(cd "$DATA_HOST_PATH" && pwd)"
    DOCKER_ARGS+=(-v "${DATA_HOST_PATH}:${DATA_CONTAINER_PATH}:ro")
fi

OUTPUT_HOST_DIR=""
OUTPUT_HOST_PATH=""
OUTPUT_CONTAINER_PATH=""
OUTPUT_CSV_HOST_PATH=""
OUTPUT_CSV_CONTAINER_PATH=""

set_output_mount_dir() {
    local requested_dir="$1"
    mkdir -p "$requested_dir"
    requested_dir="$(cd "$requested_dir" && pwd)"
    if [ -n "$OUTPUT_HOST_DIR" ] && [ "$OUTPUT_HOST_DIR" != "$requested_dir" ]; then
        echo "Error: --output-video and --output-csv must use the same host directory." >&2
        echo "       video dir: $OUTPUT_HOST_DIR" >&2
        echo "       csv dir:   $requested_dir" >&2
        exit 1
    fi
    OUTPUT_HOST_DIR="$requested_dir"
}

if [ -n "$OUTPUT_VIDEO" ]; then
    OUTPUT_HOST_BASE="$(basename "$OUTPUT_VIDEO")"
    set_output_mount_dir "$(dirname "$OUTPUT_VIDEO")"
    OUTPUT_HOST_PATH="${OUTPUT_HOST_DIR}/${OUTPUT_HOST_BASE}"
    OUTPUT_CONTAINER_PATH="/output/${OUTPUT_HOST_BASE}"
    DOCKER_ARGS+=(-e "VISIONPILOT_OUTPUT_VIDEO=${OUTPUT_CONTAINER_PATH}")
fi

if [ -n "$OUTPUT_CSV" ]; then
    OUTPUT_CSV_HOST_BASE="$(basename "$OUTPUT_CSV")"
    set_output_mount_dir "$(dirname "$OUTPUT_CSV")"
    OUTPUT_CSV_HOST_PATH="${OUTPUT_HOST_DIR}/${OUTPUT_CSV_HOST_BASE}"
    OUTPUT_CSV_CONTAINER_PATH="/output/${OUTPUT_CSV_HOST_BASE}"
    DOCKER_ARGS+=(-e "VISIONPILOT_OUTPUT_CSV=${OUTPUT_CSV_CONTAINER_PATH}")
fi

if [ -n "$OUTPUT_HOST_DIR" ]; then
    DOCKER_ARGS+=(-v "${OUTPUT_HOST_DIR}:/output:rw")
fi

# Allow to modify config outside the container
DOCKER_ARGS+=(-v "$(cd ../config && pwd)/vision_pilot.conf:/usr/share/visionpilot/config/vision_pilot.conf:ro")
DOCKER_ARGS+=(-v "$(cd ../config && pwd)/vision_pilot_test.conf:/usr/share/visionpilot/config/vision_pilot_test.conf:ro")
H_HOST_PATH="${CONFIG_DIR}/H.yaml"
if [ -n "${DATA_HOST_PATH:-}" ] && [ -f "${DATA_HOST_PATH}/H.yaml" ]; then
    H_HOST_PATH="${DATA_HOST_PATH}/H.yaml"
fi
DOCKER_ARGS+=(-v "${H_HOST_PATH}:/usr/share/visionpilot/config/H.yaml:ro")
if [ "$ENABLE_ROS2" = "ON" ]; then
    DOCKER_ARGS+=(-v "$(cd ../config && pwd)/vision_pilot_ros2.conf:/usr/share/visionpilot/config/vision_pilot_ros2.conf:ro")
fi

VISION_PILOT_CONF="${CONFIG_DIR}/vision_pilot.conf"
WEBRTC_ON="$(awk -F= '/^[[:space:]]*webrtc_on[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print tolower($2)}' "$VISION_PILOT_CONF")"
WEBRTC_PORT="$(awk -F= '/^[[:space:]]*webrtc_port[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$VISION_PILOT_CONF")"

if [ "$WEBRTC_ON" = "true" ]; then
    if ! is_valid_port "$WEBRTC_PORT"; then
        echo "Error: webrtc_on = true in $VISION_PILOT_CONF, but webrtc_port ('$WEBRTC_PORT') is missing or invalid (expected 1-65535)." >&2
        exit 1
    fi
    DOCKER_ARGS+=(-p "${WEBRTC_PORT}:${WEBRTC_PORT}")
fi

if [ -n "$V4L2" ]; then
  DOCKER_ARGS+=(--device "${V4L2}")
fi

if [ -z "$NO_DISPLAY" ]; then
    DOCKER_ARGS+=(-e "DISPLAY=${DISPLAY:-}" -v /tmp/.X11-unix:/tmp/.X11-unix:rw)
    DOCKER_ARGS+=(--device /dev/dri:/dev/dri)
    DOCKER_ARGS+=(-e "XDG_RUNTIME_DIR=/tmp/runtime-root")
    if [ -z "$NO_XHOST" ] && command -v xhost >/dev/null 2>&1; then
        echo "Granting local Docker containers X11 access (xhost +local:docker) —"
        echo "skip this with --no-xhost if you've already set it up, or --no-display"
        echo "if you don't need the visualization window at all."
        xhost +local:docker >/dev/null 2>&1 || true
    fi
else
    DOCKER_ARGS+=(-e "QT_QPA_PLATFORM=offscreen")
fi

echo "=================================================="
echo " VisionPilot Docker run"
echo "=================================================="
echo " Variant:      $VARIANT"
echo " Image tag:    $TAG"
echo " Display:      $([ -n "$NO_DISPLAY" ] && echo "disabled" || echo "enabled")"
if [ -n "$DATA_DIR" ]; then
    if [ "$DATA_HOST_PATH" = "$DATA_CONTAINER_PATH" ]; then
        echo " Data mount:   $DATA_HOST_PATH (same path in container)"
    else
        echo " Data mount:   $DATA_HOST_PATH -> $DATA_CONTAINER_PATH"
    fi
fi
echo " H.yaml:       $H_HOST_PATH"
if [ -n "$OUTPUT_VIDEO" ]; then
    echo " Output video: $OUTPUT_HOST_PATH -> $OUTPUT_CONTAINER_PATH"
fi
if [ -n "$OUTPUT_CSV" ]; then
    echo " Output CSV:   $OUTPUT_CSV_HOST_PATH -> $OUTPUT_CSV_CONTAINER_PATH"
fi
echo "=================================================="

docker run "${DOCKER_ARGS[@]}" "$TAG"

echo "${DOCKER_ARGS[@]}"

