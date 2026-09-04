# ============================================================
# install_pytorch.ps1 - PyTorch 一键自动安装 (Windows PowerShell 5.1+ / PowerShell 7)
#
# 用法 (PowerShell 中一条命令):
#   irm https://raw.githubusercontent.com/xiangbianpangde/pytorch-installer/main/install_pytorch.ps1 | iex
#
# 功能与 bash 版对齐:
#   - 必须先询问是否有 NVIDIA 显卡
#   - pip 版 PyTorch 自带 CUDA 运行时, 按驱动版本选 cu126/cu124/cu121 轮子
#   - 无驱动时提示手动安装 (Windows 无法可靠地自动化驱动安装)
#   - 网络回退: 官方源 -> 阿里云 pytorch-wheels / 清华 TUNA
#   - 用户目录含空格兼容: venv 强制装到 C:\pytorch-venv, 全程用 python.exe 绝对路径调用
# ============================================================
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; Read-Host "按回车退出"; exit 1 }

# ============================================================
# 1. 环境识别
# ============================================================
Info "检测到环境: Windows ($env:PROCESSOR_ARCHITECTURE)"

$HOME_HAS_SPACE = $false
if ($env:USERPROFILE -match "\s") {
    $HOME_HAS_SPACE = $true
    Warn "检测到用户目录含空格: $env:USERPROFILE"
    Warn "将把虚拟环境安装到无空格路径 C:\pytorch-venv 以规避 pip 启动脚本兼容问题"
}

# ============================================================
# 2. 必须先询问是否有显卡
# ============================================================
Write-Host ""
Write-Host "============================================================"
Write-Host "  是否有独立显卡 (NVIDIA GPU)?"
Write-Host "  - 有 NVIDIA 显卡请输入 y, 将安装 GPU (CUDA) 版 PyTorch"
Write-Host "  - 没有显卡 / 不确定请输入 n, 将安装 CPU 版"
Write-Host "============================================================"
$ans = Read-Host "请输入 [y/n] (默认 n)"
if ($ans -match "^[yY]") { $USER_SAYS_GPU = $true } else { $USER_SAYS_GPU = $false }

# ============================================================
# 3. Python / pip 环境准备
# ============================================================
Info "检查 Python 环境..."

$py = $null
foreach ($c in @("python", "py")) {
    try {
        $v = & $c -c "import sys; print(1 if sys.version_info >= (3, 9) else 0)" 2>$null
        if ("$v".Trim() -eq "1") { $py = $c; break }
    } catch {}
}

if (-not $py) {
    Warn "未找到 Python >= 3.9, 尝试用 winget 安装..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
        # 刷新当前会话 PATH
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        foreach ($c in @("python", "py")) {
            try {
                $v = & $c -c "import sys; print(1)" 2>$null
                if ("$v".Trim() -eq "1") { $py = $c; break }
            } catch {}
        }
    }
    if (-not $py) {
        Fail "无法自动安装 Python。请到 https://www.python.org/downloads/ 安装 (勾选 Add to PATH) 后重跑"
    }
}
Ok "使用 Python: $py"

if (& $py -m pip --version 2>$null) { } else {
    Warn "pip 不可用, 尝试 ensurepip..."
    & $py -m ensurepip --upgrade
}

# ---------- venv (规避空格路径问题) ----------
$VENV_CREATED = $false
$useVenv = Read-Host "是否创建虚拟环境 (venv) 安装? 推荐 [Y/n]"
if ($useVenv -notmatch "^[nN]") {
    # 用户目录含空格时必须用无空格路径, 否则 pip 生成的启动脚本可能异常
    $venvDir = "C:\pytorch-venv"
    try {
        New-Item -ItemType Directory -Force -Path $venvDir | Out-Null
    } catch {
        $venvDir = Join-Path $env:USERPROFILE ".pytorch-venv"
        Warn "无法创建 C:\pytorch-venv, 回退到用户目录 (若含空格可能出现启动脚本问题)"
    }
    Info "创建虚拟环境: $venvDir"
    & $py -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { Fail "venv 创建失败" }
    # 直接用 venv 内 python.exe 绝对路径, 无需激活, 也绕开 activate 脚本的路径问题
    $py = Join-Path $venvDir "Scripts\python.exe"
    $VENV_CREATED = $true
    Ok "虚拟环境就绪: $venvDir (以后使用请先运行 $venvDir\Scripts\Activate.ps1)"
} elseif ($HOME_HAS_SPACE) {
    Warn "未使用 venv 且用户目录含空格: 若 pip 安装的命令行工具无法启动,"
    Warn "请改用 'python -m <模块名>' 方式调用, 或重跑本脚本并选择创建 venv"
}

# ============================================================
# 4. GPU 分支: 驱动检查
# ============================================================
$CUDA_TAG = ""
if ($USER_SAYS_GPU) {
    $nvs = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($nvs) {
        $driverVer = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader | Select-Object -First 1)
        Ok "检测到 NVIDIA 驱动: $driverVer"
        $major = 0
        if ($driverVer -match "^\s*(\d+)") { $major = [int]$Matches[1] }
        if     ($major -ge 535) { $CUDA_TAG = "cu126" }
        elseif ($major -ge 525) { $CUDA_TAG = "cu124" }
        else                    { $CUDA_TAG = "cu121" }
        Info "依据驱动版本选择 CUDA 轮子: $CUDA_TAG (轮子自带 CUDA 运行时)"
    } else {
        Warn "您说有显卡, 但未检测到 NVIDIA 驱动 (nvidia-smi 不存在)"
        Warn "Windows 下驱动无法可靠地自动安装, 请手动处理:"
        Warn "  1. 到 https://www.nvidia.com/drivers 下载并安装驱动 (或用 GeForce Experience / NVIDIA App)"
        Warn "  2. 重启电脑后重新运行本脚本"
        $cont = Read-Host "仍要先继续安装 GPU 版 PyTorch 吗? [y/N]"
        if ($cont -match "^[yY]") { $CUDA_TAG = "cu121" } else { $USER_SAYS_GPU = $false }
    }
}

# ============================================================
# 5. 安装 PyTorch (带镜像回退与重试)
# ============================================================
Write-Host ""
Info "测试 PyPI 官方源连通性..."
$pypiCn = "https://pypi.tuna.tsinghua.edu.cn/simple"
try {
    Invoke-WebRequest -Uri "https://pypi.org/simple/" -Method Head -TimeoutSec 8 -UseBasicParsing | Out-Null
    Ok "PyPI 官方源可达"
} catch {
    Warn "官方源不可达, 安装失败时将自动回退清华 TUNA 镜像"
}

$torchPkgs = @("torch", "torchvision", "torchaudio")
$pipNet = @("--retries", "5", "--timeout", "60")

if ($USER_SAYS_GPU -and $CUDA_TAG) {
    Info "安装 GPU ($CUDA_TAG) 版 PyTorch..."
    & $py -m pip install @torchPkgs --index-url "https://download.pytorch.org/whl/$CUDA_TAG" @pipNet
    if ($LASTEXITCODE -ne 0) {
        Warn "官方轮子源安装失败, 回退阿里云镜像..."
        & $py -m pip install @torchPkgs -f "https://mirrors.aliyun.com/pytorch-wheels/$CUDA_TAG/" -i "https://pypi.org/simple" @pipNet
        if ($LASTEXITCODE -ne 0) {
            Warn "再次回退: 阿里云镜像 + 清华 TUNA 依赖源..."
            & $py -m pip install @torchPkgs -f "https://mirrors.aliyun.com/pytorch-wheels/$CUDA_TAG/" -i $pypiCn @pipNet
        }
    }
} else {
    Info "安装 CPU 版 PyTorch..."
    & $py -m pip install @torchPkgs @pipNet
    if ($LASTEXITCODE -ne 0) {
        Warn "官方 PyPI 安装失败, 回退清华 TUNA 镜像..."
        & $py -m pip install @torchPkgs -i $pypiCn @pipNet
    }
}
if ($LASTEXITCODE -ne 0) { Fail "PyTorch 安装失败, 请检查网络/代理后重跑" }

# ============================================================
# 6. 验证安装
# ============================================================
Write-Host ""
Info "验证安装..."
& $py -c "import torch; print('[ OK ] PyTorch 版本:', torch.__version__); print('[ OK ] CUDA 可用:', torch.cuda.is_available()); print('[ OK ] GPU:', torch.cuda.get_device_name(0)) if torch.cuda.is_available() else None"

Write-Host ""
Ok "==================== 全部完成 ===================="
if ($VENV_CREATED) { Ok "使用前请激活虚拟环境: C:\pytorch-venv\Scripts\Activate.ps1" }
Ok "快速自检: python -c `"import torch; print(torch.cuda.is_available())`""
Read-Host "按回车退出"
