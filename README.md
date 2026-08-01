# Dify 插件离线打包工具

Dify 安装 Python 插件时通常需要从 PyPI 下载依赖。在纯内网环境中，这会导致插件初始化失败。本项目在可联网的机器上下载目标平台的完整 wheel 依赖，并重新生成可以在内网安装的 `.difypkg`。

作者：`xiejianglei`

## 兼容方式

离线包同时包含两套安装配置，不需要指定或判断 Dify 版本：

- `requirements.txt` 使用 `--no-index` 和 `--find-links=./wheels`。
- `pyproject.toml` 保留运行时项目依赖，移除仅用于开发/测试的依赖组，并将 uv 解析环境限制为目标 Linux、CPU 架构和 Python 版本。
- 包内 `uv.toml` 开启 `offline = true`，并将 `./wheels` 配置为唯一的本地 flat index。

原始 `uv.lock` 不会放入离线包，避免 Dify Plugin Daemon 使用其中记录的公网 URL。无论 daemon 优先使用 `uv pip install` 还是 `uv sync`，依赖都只能从包内 `wheels/` 读取。

限制 uv 的目标环境很重要：否则 uv 会为 Windows、其他 CPU 架构以及默认开发依赖做通用解析，即使 Linux ARM64 的运行时依赖已经齐全，仍可能因为无关平台的 wheel 不在包中而失败。脚本兼容新的 `[dependency-groups]` 以及旧的 `[tool.uv].dev-dependencies` 写法。

该策略已针对 Dify 1.16.0 的 `langgenius/dify-plugin-daemon:0.6.3-local` 验证。未来版本只要继续支持 requirements 或 uv 项目依赖格式，就不需要修改打包命令。

## 支持的平台

- Linux AMD64 原生打包
- Linux ARM64 原生打包
- 在 Linux/WSL2 AMD64 中交叉生成 Linux ARM64 离线包

打包器自身的架构与插件 wheel 的目标架构相互独立。例如 AMD64 到 ARM64 模式仍运行 AMD64 Dify CLI，但只下载 ARM64 和平台无关的 wheel。

## 前置依赖

打包机器需要联网，并安装：

- Bash 4+
- Python 和 pip
- [uv](https://docs.astral.sh/uv/) 0.6.11 或更高版本
- `curl`、`unzip`、`realpath`
- 本项目附带的对应主机架构 Dify Plugin CLI

Ubuntu/WSL2 可以安装基础命令：

```bash
sudo apt update
sudo apt install -y python3-pip curl unzip coreutils
```

uv 可按其官方文档安装。脚本不会在运行过程中使用 `sudo` 修改系统。

## 使用方法

进入项目目录：

```bash
cd /mnt/h/code/dify-plugin-repackaging-plus
chmod +x plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh
```

### 本机架构打包

```bash
./plugin_repackaging.sh local hjlarry-database_0.0.6.difypkg
```

### AMD64 交叉打包 ARM64

```bash
./plugin_repackaging_amd64_to_arm64.sh local langgenius-openai_api_compatible_0.0.57.difypkg
```

输出文件位于当前项目目录，名称为：

```text
<原包名称>-offline.difypkg
```

### 从 Dify Marketplace 下载并打包

```bash
./plugin_repackaging.sh market <插件作者> <插件名称> <插件版本>
```

示例：

```bash
./plugin_repackaging.sh market langgenius agent 0.0.9
```

### 从 GitHub Release 下载并打包

```bash
./plugin_repackaging.sh github <仓库> <Release> <资源文件名>
```

示例：

```bash
./plugin_repackaging.sh github junjiem/dify-plugin-tools-dbquery v0.0.2 db_query.difypkg
```

## 自动目标检测

Python 版本按以下顺序确定：

1. `DIFY_PYTHON_VERSION` 环境变量。
2. 插件包内 `.python-version`。
3. `pyproject.toml` 的 `requires-python` 下限。
4. 默认 Python 3.12。

默认 wheel 平台为：

- ARM64：`manylinux_2_28_aarch64`、`manylinux2014_aarch64`
- AMD64：`manylinux_2_28_x86_64`、`manylinux2014_x86_64`

## 高级配置

正常使用不需要配置 Dify 版本。非标准环境可以覆盖：

```bash
# 指定插件运行时 Python
export DIFY_PYTHON_VERSION=3.12

# 指定目标架构：x86_64 或 aarch64
export DIFY_TARGET_ARCH=aarch64

# 逗号分隔的 pip 平台标签
export DIFY_MANYLINUX_PLATFORMS=manylinux_2_28_aarch64,manylinux2014_aarch64

# 下载依赖使用的 PyPI 镜像
export PIP_MIRROR_URL=https://mirrors.aliyun.com/pypi/simple

# pip 不在 PATH 中时指定完整命令
export DIFY_PIP_COMMAND=/path/to/venv/bin/pip
```

## 安全失败原则

脚本不会回退下载打包主机架构的 wheel。出现以下情况时会立即失败，不会生成看似成功但无法安装的包：

- 目标 Python/架构没有二进制 wheel，只有源码包。
- requirements 依赖闭包不完整或版本不匹配。
- requirements 或 pyproject 任一适用路径无法完全离线解析。
- Dify CLI 打包失败。
- 最终包缺少 `requirements.txt`、`uv.toml` 或 wheel。
- ARM64 包中发现 x86_64 wheel。

每次运行使用独立临时目录，不会复用上一次构建留下的 wheel。

## 原作者文章

[Dify 纯内网插件离线安装支持多平台多架构跨架构](https://www.cnblogs.com/xjl456852/p/18865586)
