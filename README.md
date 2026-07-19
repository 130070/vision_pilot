# VisionPilot Docker 复现记录

<p align="center">
  <a href="./output/openlane_2x2_grid.mp4">
    <img src="./output/openlane_2x2_grid.jpg" alt="VisionPilot OpenLane 2x2 复现效果展示" width="100%">
  </a>
</p>

<p align="center">
  <b>点击上方封面观看 4 组 OpenLane 复现结果拼接视频</b>
</p>

这个仓库是我对 Autoware Foundation 开源项目
[vision_pilot](https://github.com/autowarefoundation/vision_pilot)
的 Docker 复现版本。

目标不是重新介绍官方项目，而是记录我如何在一台带 NVIDIA GPU 的 Ubuntu 服务器上把环境跑通、生成结果视频，并整理出以后可以重复使用的步骤。

## 当前复现结果

我已经完成了下面这些内容：

- 使用 Docker 构建了 GPU 版本镜像：`visionpilot:gpu`
- 在容器内使用 CUDA 后端加载并运行三个 ONNX 模型：
  - `autodrive_fp32.onnx`
  - `autosteer_fp32.onnx`
  - `autospeed_fp32.onnx`
- 支持 SSH/headless 环境运行，不需要打开图形窗口
- 支持把推理可视化结果保存为 mp4 视频
- 跑通了多个 OpenLane 测试视频
- 生成了 2x2 对比视频

本仓库中可以直接查看的复现产物：

```text
output/openlane_2x2_grid.mp4
output/openlane_results/
```

## 我的复现环境

这次复现使用的服务器环境大致如下：

```text
OS: Ubuntu 24.04.3 LTS
GPU: NVIDIA GeForce RTX 4060 Ti
NVIDIA Driver: 580.159.03
CUDA in container: 13.0
Docker image: visionpilot:gpu
```

如果你使用别的 NVIDIA GPU，一般也可以复现，但需要保证：

- 主机能正常运行 `nvidia-smi`
- Docker 已安装
- NVIDIA Container Toolkit 已安装
- `docker run --gpus all ...` 能在容器里访问 GPU

## 目录结构

我把复现相关内容统一整理到了仓库根目录下：

```text
vision_pilot/
├── VisionPilot/                 # 官方项目主体代码，我在这里做了 Docker 和运行逻辑修改
├── input/                       # 输入数据，放测试视频和速度文件
│   └── openlane_sample/
│       ├── input.mp4
│       └── frame_speed.txt
├── output/                      # 输出结果视频
│   ├── openlane_2x2_grid.mp4
│   └── openlane_results/
├── data/                        # 中间数据或临时数据
├── logs/                        # 构建和运行日志、备份文件
└── tools/                       # 安装或修复环境用过的脚本
```

推荐以后也按照这个方式放文件：

- 原始输入视频放到 `input/<数据集名>/`
- 运行结果视频放到 `output/`
- 日志放到 `logs/`
- 临时脚本放到 `tools/`

## 第一次在新机器上复现

下面假设你已经有一台 Ubuntu 机器，并且 Docker 已经可以正常使用。

### 1. 检查 GPU 和 Docker

先确认主机能看到 NVIDIA GPU：

```bash
nvidia-smi
```

确认 Docker 可用：

```bash
docker --version
```

确认 Docker 可以访问 GPU：

```bash
sudo docker run --rm --gpus all nvcr.io/nvidia/cuda:13.0.0-runtime-ubuntu24.04 nvidia-smi
```

如果这一步失败，先不要继续构建 VisionPilot。需要先修好 NVIDIA 驱动、Docker 或 NVIDIA Container Toolkit。

### 2. 克隆仓库

```bash
git clone https://github.com/130070/vision_pilot.git
cd vision_pilot
```

### 3. 准备 ONNX Runtime 压缩包

为了避免 Docker 构建时从 GitHub 慢速下载导致失败，我把 Dockerfile 改成使用本地 ONNX Runtime 包。

你需要把下面这个文件放到：

```text
VisionPilot/docker/ort.tgz
```

对应版本：

```text
ONNX Runtime GPU 1.26.0
```

下载地址：

```text
https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/onnxruntime-linux-x64-gpu-1.26.0.tgz
```

在服务器上可以这样下载：

```bash
cd VisionPilot/docker
wget -O ort.tgz https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/onnxruntime-linux-x64-gpu-1.26.0.tgz
```

如果服务器访问 GitHub 很慢，可以在本机下载好后传到服务器：

```powershell
scp "D:\你的路径\onnxruntime-linux-x64-gpu-1.26.0.tgz" liang@服务器IP:~/vision_pilot/VisionPilot/docker/ort.tgz
```

注意：`ort.tgz` 很大，不建议直接提交到 GitHub 普通仓库。

### 4. 构建 Docker 镜像

```bash
cd ~/vision_pilot/VisionPilot/docker
sudo ./build.sh --gpu
```

构建完成后应该看到：

```text
Build complete: visionpilot:gpu
```

也可以检查镜像：

```bash
sudo docker images | grep visionpilot
```

### 5. 验证容器 GPU

```bash
sudo docker run --rm --gpus all --entrypoint /bin/bash visionpilot:gpu -lc "nvidia-smi"
```

如果容器里能看到 GPU，说明 Docker GPU 环境是通的。

## 运行一个测试视频

VisionPilot 视频模式需要两个输入文件：

```text
input.mp4           # 视频
frame_speed.txt     # 每一行一个速度值
```

当前仓库示例路径：

```text
input/openlane_sample/input.mp4
input/openlane_sample/frame_speed.txt
```

运行并保存输出视频：

```bash
cd ~/vision_pilot/VisionPilot/docker
sudo ./run.sh --gpu --no-display \
  --data ~/vision_pilot/input/openlane_sample:/data \
  --output-video ~/vision_pilot/output/openlane_result.mp4
```

参数解释：

```text
--gpu
    使用 GPU 镜像 visionpilot:gpu

--no-display
    不打开 GUI 窗口，适合 SSH 服务器或无显示器环境

--data ~/vision_pilot/input/openlane_sample:/data
    把宿主机输入目录挂载到容器内 /data

--output-video ~/vision_pilot/output/openlane_result.mp4
    把可视化结果保存为 mp4
```

运行成功后，输出文件在：

```text
~/vision_pilot/output/openlane_result.mp4
```

## 配置文件说明

主要配置文件有两个：

```text
VisionPilot/config/vision_pilot.conf
VisionPilot/config/vision_pilot_test.conf
```

`vision_pilot.conf` 里关键配置：

```conf
source.mode         = video
engine.provider     = cuda
visualization_on    = false
```

`engine.provider` 必须使用项目支持的值：

```text
cpu | cuda | tensorrt
```

我这里使用的是：

```conf
engine.provider     = cuda
```

`vision_pilot_test.conf` 里关键配置：

```conf
source.input_video         = /data/input.mp4
source.input_vehicle_speed = /data/frame_speed.txt
source.dataset             = open_lane
```

注意这里写的是容器内路径 `/data/...`，不是服务器宿主机路径。

## 运行你自己的数据集

假设你有一个新数据集：

```text
input/test_open_lane_2/
├── input.mp4
├── frame_speed.txt
└── H.yaml              # 可选，有些数据集会提供
```

### 1. 上传数据

在 Windows PowerShell 里运行：

```powershell
scp "D:\chrome\test_open_lane_2\input.mp4" liang@服务器IP:~/vision_pilot/input/test_open_lane_2/input.mp4
scp "D:\chrome\test_open_lane_2\frame_speed.txt" liang@服务器IP:~/vision_pilot/input/test_open_lane_2/frame_speed.txt
scp "D:\chrome\test_open_lane_2\H.yaml" liang@服务器IP:~/vision_pilot/input/test_open_lane_2/H.yaml
```

如果没有 `H.yaml`，最后一条可以跳过。

### 2. 如果数据集带 H.yaml

如果数据集提供了自己的 `H.yaml`，建议先备份当前配置：

```bash
cp ~/vision_pilot/VisionPilot/config/H.yaml ~/vision_pilot/VisionPilot/config/H.yaml.bak
```

再复制新数据集的 `H.yaml`：

```bash
cp ~/vision_pilot/input/test_open_lane_2/H.yaml ~/vision_pilot/VisionPilot/config/H.yaml
```

我已经修改了 `run.sh`，运行容器时会把 `VisionPilot/config/H.yaml` 挂载进去，因此不需要为了 H.yaml 重新构建镜像。

### 3. 运行数据集

因为容器内输入路径固定挂载为 `/data`，所以 `vision_pilot_test.conf` 保持下面这样即可：

```conf
source.input_video         = /data/input.mp4
source.input_vehicle_speed = /data/frame_speed.txt
```

然后运行：

```bash
cd ~/vision_pilot/VisionPilot/docker
sudo ./run.sh --gpu --no-display \
  --data ~/vision_pilot/input/test_open_lane_2:/data \
  --output-video ~/vision_pilot/output/test_open_lane_2_result.mp4
```

## 批量处理多个数据集

如果你已经准备好了：

```text
input/test_open_lane_2/
input/test_open_lane_5/
input/test_open_lane_6/
input/test_open_lane_10/
```

可以用下面的循环依次生成结果：

```bash
cd ~/vision_pilot

for name in test_open_lane_2 test_open_lane_5 test_open_lane_6 test_open_lane_10; do
  echo "Processing ${name}"

  if [ -f "input/${name}/H.yaml" ]; then
    cp "input/${name}/H.yaml" "VisionPilot/config/H.yaml"
  fi

  sudo ./VisionPilot/docker/run.sh --gpu --no-display \
    --data "$PWD/input/${name}:/data" \
    --output-video "$PWD/output/${name}_result.mp4"
done
```

生成结果：

```text
output/test_open_lane_2_result.mp4
output/test_open_lane_5_result.mp4
output/test_open_lane_6_result.mp4
output/test_open_lane_10_result.mp4
```

## 生成 2x2 对比视频

服务器上需要有 `ffmpeg`：

```bash
ffmpeg -version
```

下面命令会把四个结果视频拼成一个 2x2 视频：

```bash
cd ~/vision_pilot

ffmpeg -y \
  -i output/test_open_lane_2_result.mp4 \
  -i output/test_open_lane_5_result.mp4 \
  -i output/test_open_lane_6_result.mp4 \
  -i output/test_open_lane_10_result.mp4 \
  -filter_complex "[0:v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS[v0];[1:v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS[v1];[2:v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS[v2];[3:v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS[v3];[v0][v1][v2][v3]xstack=inputs=4:layout=0_0|960_0|0_540|960_540:shortest=1[v]" \
  -map "[v]" -an -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
  output/openlane_2x2_grid.mp4
```

布局：

```text
左上：test_open_lane_2     右上：test_open_lane_5
左下：test_open_lane_6     右下：test_open_lane_10
```

## 从服务器下载结果视频

在 Windows PowerShell 里运行：

```powershell
scp liang@服务器IP:~/vision_pilot/output/openlane_result.mp4 "D:\chrome\openlane_result.mp4"
scp liang@服务器IP:~/vision_pilot/output/openlane_2x2_grid.mp4 "D:\chrome\openlane_2x2_grid.mp4"
```

如果你的视频文件名不同，把命令里的文件名改成实际名字即可。

## 常见问题

### 1. 看不到视频窗口

如果运行命令里带了：

```bash
--no-display
```

就不会显示窗口，只会在终端输出日志，并保存视频文件。

在 SSH 服务器上推荐使用 `--no-display`。

### 2. 出现 ONNX Runtime warning

类似：

```text
Some nodes were not assigned to the preferred execution providers
```

这是 ONNX Runtime 的性能提醒，通常不是错误。日志中如果能看到：

```text
[OnnxEngine] provider=cuda
[AutoDrive] Ready
[AutoSteer] Ready
[AutoSpeed] Ready
```

说明模型已经加载成功。

### 3. `source.video_path not found`

说明 `vision_pilot_test.conf` 里的路径不对。

容器内路径应该写：

```conf
source.input_video         = /data/input.mp4
source.input_vehicle_speed = /data/frame_speed.txt
```

同时运行时必须挂载数据目录：

```bash
--data ~/vision_pilot/input/你的数据集:/data
```

### 4. `Unknown provider 'gpu'`

`engine.provider` 不能写 `gpu`。

应该改成：

```conf
engine.provider     = cuda
```

### 5. Qt / xcb 报错

如果看到：

```text
qt.qpa.xcb: could not connect to display
```

说明当前环境没有图形显示。使用：

```bash
--no-display
```

本仓库的 `run.sh` 会在 `--no-display` 时自动设置：

```text
QT_QPA_PLATFORM=offscreen
```

### 6. Docker 构建时下载很慢

这个仓库已经把 ONNX Runtime 下载改成了本地包方式：

```text
VisionPilot/docker/ort.tgz
```

如果没有这个文件，构建会失败。

如果 GitHub 下载慢，可以在网络更好的电脑上下载 `ort.tgz`，再传到服务器。

### 7. 不要随便 `apt autoremove` NVIDIA 包

Ubuntu 可能提示某些 NVIDIA 包可以 autoremove。不要在没有确认的情况下执行：

```bash
sudo apt autoremove
```

否则可能破坏 GPU 驱动环境。

## 我对原项目做过的关键修改

相对官方项目，我为了复现和服务器运行做了这些改动：

- Dockerfile 使用本地 `docker/ort.tgz`，避免构建时下载 ONNX Runtime 失败
- pip 安装使用国内镜像和更长超时
- `run.sh` 增加 `--output-video`，支持保存输出视频
- `run.sh` 在 `--no-display` 时自动使用 Qt offscreen 后端
- `run.sh` 挂载 `H.yaml`，方便替换不同数据集的 homography
- 主程序支持 `VISIONPILOT_OUTPUT_VIDEO` 环境变量，将可视化结果写入 mp4
- 修正程序视频跑完后成功退出但返回码为 1 的问题
- 整理了复现输入、输出、日志和工具目录

## 更新 GitHub

修改 README 或代码后，可以这样提交：

```bash
cd ~/vision_pilot
git status
git add README.md VisionPilot/docker/run.sh VisionPilot/app/vision_pilot.cpp
git commit -m "docs: add Docker reproduction guide"
git push origin main
```

如果 `git push` 要求输入密码，GitHub 现在需要填写 Personal Access Token，而不是账号登录密码。

## 致谢

本仓库基于 Autoware Foundation 的
[vision_pilot](https://github.com/autowarefoundation/vision_pilot)
项目完成复现。原项目许可证和版权说明请参考官方仓库及本仓库中的 `LICENSE`。
