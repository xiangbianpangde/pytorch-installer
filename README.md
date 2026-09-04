# pytorch-installer

PyTorch 一键自动安装脚本：自动识别 macOS / Linux / WSL / Windows(Git Bash)，安装前必须询问是否有 NVIDIA 显卡，有卡缺驱动时自动安装驱动（pip 版 PyTorch 轮子自带 CUDA 运行时，无需另装 CUDA Toolkit），无卡装 CPU 版（Apple Silicon 自带 MPS）。内置清华 TUNA / 阿里云镜像自动回退，兼容 Windows 空格路径。

## 一条命令安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xiangbianpangde/pytorch-installer/main/install_pytorch.sh)"
```

## 功能

- 环境识别：macOS / Linux / WSL / Windows-GitBash，x86_64 / arm64
- 强制询问是否有 NVIDIA 显卡（y/n）
- 有卡无驱动：自动安装 NVIDIA 驱动（apt / ubuntu-drivers / dnf / pacman）
- 按驱动版本自动选 CUDA 轮子：≥535 → cu126，≥525 → cu124，更旧 → cu121
- 网络：官方源不通自动切清华 TUNA / 阿里云 pytorch-wheels 镜像，pip 带 retry 与超时
- Windows 用户目录含空格：venv 强制装到 `C:\pytorch-venv`，全程 `python -m` 调用
- 装完自动验证 `torch.cuda.is_available()` / MPS / GPU 名称

## 可选环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PIP_RETRIES` | 5 | pip 重试次数 |
| `PIP_TIMEOUT` | 60 | pip 单次连接超时（秒） |
