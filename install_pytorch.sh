#!/usr/bin/env bash
# ============================================================
# install_pytorch.sh — PyTorch 一键自动安装脚本 v2
#
# 功能:
#   1. 自动识别操作系统 (macOS / Linux / WSL / Windows-GitBash) 与架构
#   2. 必须先询问用户是否有显卡 (NVIDIA GPU)
#   3. 有显卡但驱动缺失时, 尝试自动安装 NVIDIA 驱动
#      (pip 版 PyTorch 自带 CUDA 运行时, 通常只需驱动, 无需 CUDA Toolkit)
#   4. 无显卡: macOS (Apple Silicon 自带 MPS) / Linux / Windows 装 CPU 版
#   5. 网络自适应: 官方源不通自动切清华 TUNA / 阿里云 PyTorch 轮子镜像, 带重试
#   6. Windows 空格路径兼容: venv 强制放无空格路径, 全程 python -m 调用
#   7. 安装完成后自动验证
#
# 用法:
#   bash install_pytorch.sh
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/install_pytorch.sh)"
#
# 注意: 脚本内所有交互读取均走 /dev/tty, 支持 `curl | bash` 管道方式
# ============================================================
set -euo pipefail

# ---------- 颜色输出 ----------
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_OFF='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_OFF=''
fi
info()  { printf "${C_BLUE}[INFO]${C_OFF} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[ OK ]${C_OFF} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_OFF} %s\n" "$*"; }
fail()  { printf "${C_RED}[FAIL]${C_OFF} %s\n" "$*"; exit 1; }

# ---------- 交互读取 (强制走终端, 兼容 curl | bash) ----------
ask() {
  local __prompt="$1" __default="${2:-}" __ans=""
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt" __ans < /dev/tty || true
  else
    warn "无可用终端输入, 使用默认值: ${__default:-无}"
    __ans="$__default"
  fi
  if [ -z "$__ans" ]; then __ans="$__default"; fi
  printf '%s' "$__ans"
}

# ============================================================
# 网络与镜像配置 (可用环境变量覆盖)
# ============================================================
PIP_RETRIES="${PIP_RETRIES:-5}"
PIP_TIMEOUT="${PIP_TIMEOUT:-60}"   # pip 单次连接超时(秒)

pypi_index="https://pypi.org/simple"                                  # 官方 PyPI
pypi_mirror_cn="https://pypi.tuna.tsinghua.edu.cn/simple"             # 清华 TUNA
pytorch_official="https://download.pytorch.org/whl"                   # PyTorch 官方轮子源
pytorch_mirror_cn="https://mirrors.aliyun.com/pytorch-wheels"         # 阿里云 PyTorch 轮子镜像

check_url() { curl -fsSL -m 8 -o /dev/null "$1" 2>/dev/null; }

pick_pypi_index() {
  info "测试 PyPI 官方源连通性..."
  if check_url "https://pypi.org/simple/"; then
    ok "PyPI 官方源可达"
  elif check_url "$pypi_mirror_cn"; then
    warn "官方源不可达, 自动切换清华 TUNA 镜像"
    pypi_index="$pypi_mirror_cn"
  else
    warn "官方源与清华镜像均不可达, 将按重试策略尝试 (如有代理请先配置后重跑)"
  fi
}

# ============================================================
# 1. 环境识别
# ============================================================
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)  PLATFORM="macOS" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      PLATFORM="WSL"
    else
      PLATFORM="Linux"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="Windows-GitBash" ;;
  *) fail "不支持的操作系统: $OS" ;;
esac

info "检测到环境: $PLATFORM ($ARCH)"

# ---------- Windows 空格路径预警 ----------
# 已知问题: 用户目录含空格(或中文)时, pip 生成的 *-script.py 包装器
# 和 conda 的 activate 脚本可能无法正确处理带空格路径。
# 应对: venv 统一放无空格路径 + 全程用 python -m 调用 (见下文)。
HOME_HAS_SPACE=0
case "$HOME" in
  *" "*) HOME_HAS_SPACE=1 ;;
esac
if [ "$HOME_HAS_SPACE" = "1" ] && [ "$PLATFORM" = "Windows-GitBash" ]; then
  warn "检测到用户目录含空格/非 ASCII 字符: $HOME"
  warn "将把虚拟环境安装到无空格路径 C:\\pytorch-venv 以规避启动脚本兼容问题"
fi

# ============================================================
# 2. 必须先询问是否有显卡 (用户明确要求)
# ============================================================
echo ""
echo "============================================================"
echo "  是否有独立显卡 (NVIDIA GPU)?"
echo "  - 有 NVIDIA 显卡请输入 y, 将安装 GPU (CUDA) 版 PyTorch"
echo "  - 没有显卡 / Mac / 不确定请输入 n, 将安装 CPU 版"
echo "    (Apple Silicon Mac 会自动支持 MPS 加速, 无需显卡)"
echo "============================================================"
HAS_GPU_INPUT="$(ask "请输入 [y/n] (默认 n): " "n")"

case "$(printf '%s' "$HAS_GPU_INPUT" | tr '[:upper:]' '[:lower:]')" in
  y|yes) USER_SAYS_GPU=1 ;;
  *)     USER_SAYS_GPU=0 ;;
esac

# ============================================================
# 3. Python / pip 环境准备
# ============================================================
echo ""
info "检查 Python 环境..."

PYTHON_CMD=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)" 2>/dev/null; then
      PYTHON_CMD="$cand"; break
    fi
  fi
done

if [ -z "$PYTHON_CMD" ]; then
  warn "未找到 Python >= 3.9, 尝试自动安装..."
  case "$PLATFORM" in
    macOS)
      if command -v brew >/dev/null 2>&1; then
        brew install python || fail "brew 安装 python 失败, 请手动安装 Python 3.9+"
      else
        fail "macOS 未安装 Python 且无 Homebrew。请先安装: https://brew.sh 然后重试"
      fi
      ;;
    Linux|WSL)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pip
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm python python-pip
      else
        fail "无法自动安装 Python, 请手动安装 Python 3.9+ 后重试"
      fi
      PYTHON_CMD="python3"
      ;;
    Windows-GitBash)
      fail "Windows 下请先安装 Python: https://www.python.org/downloads/ (勾选 Add to PATH)"
      ;;
  esac
fi

ok "使用 Python: $PYTHON_CMD ($("$PYTHON_CMD" --version 2>&1))"

# pip 可用性
if ! "$PYTHON_CMD" -m pip --version >/dev/null 2>&1; then
  warn "pip 不可用, 尝试安装..."
  "$PYTHON_CMD" -m ensurepip --upgrade || true
  if [ "$PLATFORM" = "macOS" ]; then
    "$PYTHON_CMD" -m ensurepip --upgrade 2>/dev/null || brew reinstall python
  fi
  "$PYTHON_CMD" -m pip --version >/dev/null 2>&1 || fail "pip 安装失败, 请手动安装 pip"
fi

# ---------- venv (规避 PEP 668 / Windows 空格问题) ----------
VENV_CREATED=0
if [ "$PLATFORM" != "macOS" ]; then
  USE_VENV="$(ask "是否创建虚拟环境 (venv) 安装? 推荐 [Y/n]: " "y")"
  case "$(printf '%s' "$USE_VENV" | tr '[:upper:]' '[:lower:]')" in
    n|no) USE_VENV=0 ;;
    *)    USE_VENV=1 ;;
  esac
  if [ "$USE_VENV" = "1" ]; then
    # Windows: venv 强制放无空格路径, 避免用户目录带空格时
    # pip/conda 生成的启动脚本 (Scripts/*.exe 包装器, activate 脚本) 出错
    if [ "$PLATFORM" = "Windows-GitBash" ]; then
      VENV_DIR="/c/pytorch-venv"
      if ! mkdir -p "$VENV_DIR" 2>/dev/null; then
        VENV_DIR="${HOME}/.pytorch-venv"
        warn "无法创建 C:\\pytorch-venv, 回退到用户目录 (若含空格可能出现启动脚本问题)"
      fi
    else
      VENV_DIR="${HOME}/.pytorch-venv"
    fi

    info "创建虚拟环境: $VENV_DIR"
    "$PYTHON_CMD" -m venv "$VENV_DIR" || fail "venv 创建失败"
    # shellcheck disable=SC1091
    . "$VENV_DIR/bin/activate"
    PYTHON_CMD="python"
    VENV_CREATED=1
    ok "虚拟环境已激活。以后使用请先执行: source $VENV_DIR/bin/activate"
  elif [ "$HOME_HAS_SPACE" = "1" ] && [ "$PLATFORM" = "Windows-GitBash" ]; then
    warn "未使用 venv 且用户目录含空格: 后续若 pip 安装的命令行工具无法启动,"
    warn "请改用 'python -m <模块名>' 方式调用, 或重跑本脚本并选择创建 venv"
  fi
fi

# ============================================================
# 4. GPU 分支: 驱动检查与自动安装
# ============================================================
install_nvidia_driver() {
  info "尝试自动安装 NVIDIA 驱动..."
  case "$PLATFORM" in
    Linux|WSL)
      if command -v apt-get >/dev/null 2>&1; then
        if command -v ubuntu-drivers >/dev/null 2>&1; then
          sudo ubuntu-drivers autoinstall || sudo apt-get install -y nvidia-driver-550
        else
          sudo apt-get update && sudo apt-get install -y nvidia-driver-550
        fi
        warn "驱动安装完成, 通常需要重启后生效: sudo reboot"
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y akmod-nvidia || {
          fail "Fedora 需先启用 RPM Fusion, 参见: https://rpmfusion.org"
        }
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm nvidia nvidia-utils
      else
        fail "不支持的发行版, 请手动安装 NVIDIA 驱动: https://www.nvidia.com/drivers"
      fi
      ;;
    Windows-GitBash)
      fail "Windows 请手动安装驱动: https://www.nvidia.com/drivers (装完重启后重跑本脚本)"
      ;;
  esac
}

# 依据驱动版本选择 PyTorch CUDA 轮子标签 (pip 轮子自带 CUDA 运行时)
pick_cuda_tag() {
  local drv="${1:-}" major
  major="$(printf '%s' "$drv" | cut -d. -f1 | tr -dc '0-9')"
  case "$major" in
    "") echo "cu126" ;;
    *)
      if [ "$major" -ge 535 ]; then echo "cu126"
      elif [ "$major" -ge 525 ]; then echo "cu124"
      else echo "cu121"
      fi
      ;;
  esac
}

CUDA_TAG=""
if [ "$USER_SAYS_GPU" = "1" ]; then
  if [ "$PLATFORM" = "macOS" ]; then
    warn "macOS 不支持 NVIDIA CUDA, 将按无显卡 (CPU/MPS) 方式安装"
    USER_SAYS_GPU=0
  else
    if command -v nvidia-smi >/dev/null 2>&1; then
      DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo '?')"
      ok "检测到 NVIDIA 驱动: $DRIVER_VER"
      CUDA_TAG="$(pick_cuda_tag "$DRIVER_VER")"
      info "依据驱动版本选择 CUDA 轮子: $CUDA_TAG (轮子自带 CUDA 运行时)"
    else
      warn "您说有显卡, 但未检测到 NVIDIA 驱动 (nvidia-smi 不存在)"
      CONFIRM_DRV="$(ask "是否自动安装 NVIDIA 驱动? [Y/n]: " "y")"
      case "$(printf '%s' "$CONFIRM_DRV" | tr '[:upper:]' '[:lower:]')" in
        n|no) warn "跳过驱动安装。注意: 无驱动时 GPU 版 PyTorch 无法使用 CUDA" ;;
        *)    install_nvidia_driver ;;
      esac
      CUDA_TAG="cu121"   # 驱动刚装/未知版本, 用兼容性最好的 cu121
    fi
  fi
fi

# ============================================================
# 5. 安装 PyTorch (带镜像回退与重试)
# ============================================================
echo ""
pick_pypi_index

TORCH_PKGS="torch torchvision torchaudio"
PIP_NET_ARGS="--retries $PIP_RETRIES --timeout $PIP_TIMEOUT"

install_torch_cpu() {
  # $1 = pip index url
  # shellcheck disable=SC2086
  "$PYTHON_CMD" -m pip install $TORCH_PKGS -i "$1" $PIP_NET_ARGS
}

install_torch_gpu_official() {
  # $1 = cuda tag
  # shellcheck disable=SC2086
  "$PYTHON_CMD" -m pip install $TORCH_PKGS \
    --index-url "$pytorch_official/$1" $PIP_NET_ARGS
}

install_torch_gpu_mirror() {
  # $1 = cuda tag;  轮子来自阿里云镜像, 依赖走已选 PyPI 源
  # shellcheck disable=SC2086
  "$PYTHON_CMD" -m pip install $TORCH_PKGS \
    -f "$pytorch_mirror_cn/$1/" -i "$pypi_index" $PIP_NET_ARGS
}

if [ "$USER_SAYS_GPU" = "1" ]; then
  info "安装 GPU ($CUDA_TAG) 版 PyTorch..."

  # 优先官方轮子源; 不通或安装失败则回退阿里云镜像
  if check_url "$pytorch_official/$CUDA_TAG/torch/"; then
    ok "PyTorch 官方轮子源可达"
    install_torch_gpu_official "$CUDA_TAG" \
      || { warn "官方源安装失败, 回退阿里云镜像..."; install_torch_gpu_mirror "$CUDA_TAG"; }
  elif check_url "$pytorch_mirror_cn/$CUDA_TAG/"; then
    warn "官方轮子源不可达, 使用阿里云镜像"
    install_torch_gpu_mirror "$CUDA_TAG"
  else
    warn "官方源与镜像源探测均失败, 仍先尝试官方源 (可能只是探测接口不通)"
    install_torch_gpu_official "$CUDA_TAG" \
      || { warn "回退阿里云镜像..."; install_torch_gpu_mirror "$CUDA_TAG"; }
  fi
else
  info "安装 CPU 版 PyTorch (macOS Apple Silicon 自带 MPS 加速)..."
  install_torch_cpu "$pypi_index" \
    || {
      if [ "$pypi_index" != "$pypi_mirror_cn" ]; then
        warn "官方 PyPI 安装失败, 回退清华 TUNA 镜像..."
        pypi_index="$pypi_mirror_cn"
        install_torch_cpu "$pypi_index"
      else
        fail "CPU 版安装失败: 官方源与清华镜像均不可用, 请检查网络/代理后重跑"
      fi
    }
fi

# ============================================================
# 6. 验证安装
# ============================================================
echo ""
info "验证安装..."
"$PYTHON_CMD" - <<'PYEOF'
import sys
try:
    import torch
except Exception as e:
    print(f"[FAIL] torch 导入失败: {e}"); sys.exit(1)

print(f"[ OK ] PyTorch 版本: {torch.__version__}")
print(f"[ OK ] CUDA 可用: {torch.cuda.is_available()}")
if torch.backends.mps.is_available():
    print("[ OK ] MPS (Apple Silicon 加速) 可用")
if torch.cuda.is_available():
    print(f"[ OK ] GPU: {torch.cuda.get_device_name(0)}")
PYEOF

echo ""
ok "==================== 全部完成 ===================="

# ============================================================
# 7. 使用指南
# ============================================================
echo ""
info "如何使用 PyTorch (快速上手指南)"
echo "------------------------------------------------------------"

if [ "$VENV_CREATED" = "1" ]; then
  echo " 第 0 步: 每次使用前先激活虚拟环境"
  echo "   source $VENV_DIR/bin/activate"
  echo ""
fi

echo " 1. 打开 Python 即可用: import torch"
echo ""
echo " 2. 自动选择计算设备 (有 GPU 用 GPU, Mac 用 MPS, 否则 CPU):"
echo ""
cat <<'USAGE'
    import torch
    if torch.cuda.is_available():
        device = "cuda"          # NVIDIA 显卡
    elif torch.backends.mps.is_available():
        device = "mps"           # Apple Silicon Mac
    else:
        device = "cpu"
    print(f"当前设备: {device}")

USAGE

echo " 3. 最小可运行示例 (把下面内容存为 demo.py, 运行 python demo.py):"
echo ""
cat <<'USAGE'
    import torch
    device = "cuda" if torch.cuda.is_available() else "cpu"

    x = torch.randn(3, 3, device=device)   # 张量放到 GPU/MPS/CPU
    y = x @ x.T                            # 矩阵乘法
    print("结果张量:", y)

    # 一个 30 秒的迷你训练示例
    w = torch.tensor([1.0], device=device, requires_grad=True)
    optimizer = torch.optim.SGD([w], lr=0.1)
    for step in range(100):
        loss = (w - 5) ** 2                # 目标: 让 w 接近 5
        loss.backward()
        optimizer.step()
        optimizer.zero_grad()
    print(f"训练后 w = {w.item():.4f} (应接近 5)")

USAGE

echo " 4. 常用操作:"
echo "   - 装其他库 (进虚拟环境后): pip install numpy matplotlib"
echo "   - 查看显卡是否生效:        print(torch.cuda.is_available())"
echo "   - 保存/加载模型:           torch.save(model, 'm.pt') / torch.load('m.pt')"
echo "   - 官方入门教程 (中文):      https://pytorch.org/tutorials/"
echo "------------------------------------------------------------"
ok "快速自检: python -c \"import torch; print(torch.cuda.is_available())\""
