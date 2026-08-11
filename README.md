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

该策略已针对 Dify 1.16.0 的 `langgenius/dify-plugin-daemon:0.6.3-local` 验证。脚本根据插件 manifest 等元数据选择 Python 版本，并按目标平台参数解析依赖，不维护 Dify 发布版本白名单，因此通常不需要随 Dify 版本更换打包命令。但未来若 Dify 改变插件清单、依赖格式或运行时安装协议，仍需要重新验证，工具无法承诺兼容所有未来变化。

## 支持的平台

- Linux AMD64 原生打包
- Linux ARM64 原生打包
- 在 Linux/WSL2 AMD64 中交叉生成 Linux ARM64 离线包

打包器自身的架构与插件 wheel 的目标架构相互独立。例如 AMD64 到 ARM64 模式仍运行 AMD64 Dify CLI，但只下载 ARM64 和平台无关的 wheel。

## 前置依赖

打包机器需要联网，并安装：

- Bash 4+
- Python 和 pip
- [uv](https://docs.astral.sh/uv/) 0.7.21 或更高版本（需要 `uv sync --python-platform`）
- `curl`、`unzip`、`realpath`
- 本项目附带的对应主机架构 Dify Plugin CLI

Ubuntu/WSL2 可以安装基础命令：

```bash
sudo apt update
sudo apt install -y python3-pip curl unzip coreutils
```

uv 可按其官方文档安装。脚本不会在运行过程中使用 `sudo` 修改系统。
启动时会检查 uv 版本；版本过旧会直接给出最低版本提示，不会进行不可靠的降级验证。

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
2. `manifest.yaml` 的 `meta.runner.version`。
3. 插件包内 `.python-version`。
4. `pyproject.toml` 的 `requires-python` 下限。
5. 默认 Python 3.12。

manifest、`.python-version` 或覆盖变量可以写 `3.12` 或 `3.12.7`；脚本会统一按 CPython 主次版本 `3.12` 选择 ABI 和平台依赖。manifest 是 Dify 实际选择插件运行器的依据，因此优先于开发环境文件；缺少或无法识别时才继续回退。

默认 wheel 平台为：

- ARM64：`manylinux_2_28_aarch64`、`manylinux2014_aarch64`
- AMD64：`manylinux_2_28_x86_64`、`manylinux2014_x86_64`

## SOCKS 代理自动修复

脚本会识别 `http_proxy`、`https_proxy`、`all_proxy` 及对应大写变量中的 `socks4`、`socks4a`、`socks5` 和 `socks5h` 地址。如果选中的 pip 缺少 PySocks，脚本会自动：

1. 使用 curl 从当前 `PIP_MIRROR_URL` 读取 PySocks simple 索引。
2. 下载通用的 `PySocks==1.7.1` wheel，并在索引提供 SHA-256 时校验文件。
3. 只安装到本次构建的临时 staging 目录。
4. 仅为本次 `pip download` 注入临时 `PYTHONPATH`，构建完成后自动清理。

这个过程不会修改系统 Python、虚拟环境或 Conda 环境。没有 SOCKS 代理，或者 pip 已经支持 SOCKS 时，继续原来的下载路径，不创建 bootstrap 目录。

部分新版 pip 的 truststore 适配器会错误地把 `proxy_ssl_context` 传给 SOCKS 连接池，表现为 `PoolKey ... key_proxy_ssl_context`。脚本仅在首次下载精确命中该错误时，自动使用 pip 的 `legacy-certs` 兼容模式重试一次；普通下载和其他失败不会触发该回退。

如需禁止自动补齐并在缺少 PySocks 时直接失败：

```bash
export DIFY_AUTO_FIX_SOCKS=0
```

## 纯 Python 源码依赖自动补齐

脚本始终先按目标 Python、ABI 和 Linux 架构执行严格的纯 wheel 解析，`--only-binary=:all:` 仍是默认边界。只有 pip 返回可严格确认的“某个依赖没有可用 wheel”结果时，才会一次处理一个通用源码包；网络、DNS、代理、认证、TLS、证书、超时、哈希或版本冲突等失败都会保持关闭状态，不会触发源码构建。每接纳一个 wheel 后，脚本都会带上已经验证的本地 wheel 重新执行完整的 binary-only 依赖解析。相同候选重复出现或累计达到 16 个时会停止。

这个机制没有包名白名单。例如 `records[all]` 的依赖闭包解析到仅发布源码包的 `docopt` 时，`docopt` 可以成为候选；这只是通用行为示例，不是针对 records、docopt 或某个插件的特殊规则。pip 对无效 extra 的警告不会让脚本改写原始 requirements，最终是否成功仍由完整解析结果决定。

源码构建会执行第三方 PEP 517 构建代码。Linux 监督器使用 `/proc` 和 `prctl` 跟踪构建进程，并在超时或取消时终止其后代进程树；只有监督结束后才允许进入接纳步骤。源码包必须具有安全的归档结构和匹配的名称，构建结果也必须同时满足以下条件：

- wheel 文件名和元数据中的名称、版本一致；
- `Root-Is-Purelib: true`，且所有 wheel 标签都是 `none-any`；
- 归档路径、类型、大小和压缩结构通过安全校验；
- 不含 `.so`、`.pyd`、`.dll`、`.dylib` 等原生后缀，也不含 ELF、PE 或 Mach-O 原生二进制特征。

带原生扩展的源码依赖、交叉编译和回退使用打包主机架构都不受支持，遇到这些情况会明确失败。最终 `.difypkg` 只包含完整解析得到的 wheel，不包含源码包、构建目录、缓存、受管 Python 或原始日志。

正式的 `*-offline.difypkg` 只在打包器完成且整个归档通过离线内容和 ZIP 完整性校验后，才从同一输出目录中的受控临时文件原子替换。原子替换完成就是对外提交点：提交点之前的失败、崩溃或取消不会把半成品暴露在正式路径，并会保留已有的有效离线包；提交点之后到达的取消信号不会把已经成功提交的新包改报为失败。成功时新包一次性替换旧包，临时输出目录同样会被精确清理，不会递归删除项目目录或其他输出。

协调器日志、源码 staging、uv 缓存和受管 Python 都创建在权限受控的 Linux `/tmp/dify-plugin-coordinator.*` 中，并在成功、失败或取消后清理。这样设计是因为 WSL 下的 Windows 挂载盘通常使用 DrvFS，权限位可能表现为 `0777`，不适合保存第三方构建过程和原始诊断。本功能面向 WSL/Linux 上运行的 Dify 工具链；它不会向调用者的系统 Python、虚拟环境或 Conda 环境安装包，也不会修改这些环境。

严格 wheel 下载路径仍可按 pip 的能力使用带认证信息的索引 URL。但自动第三方源码修复会在任何下载或构建副作用之前拒绝含 userinfo、query 或 fragment 的认证索引，避免凭据进入第三方构建工具、配置或诊断。需要源码修复时，请改用可信的无认证镜像、预先提供合格 wheel，或禁用此功能。

自动补齐默认开启。如需完全禁止第三方源码构建：

```bash
export DIFY_AUTO_BUILD_PURE_SDIST=0
```

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

# 禁止临时补齐 pip 的 SOCKS 支持
export DIFY_AUTO_FIX_SOCKS=0

# 禁止从源码构建并验证纯 Python 通用 wheel
export DIFY_AUTO_BUILD_PURE_SDIST=0
```

## 安全失败原则

脚本不会回退下载打包主机架构的 wheel。出现以下情况时会立即失败，不会生成看似成功但无法安装的包：

- 目标 Python/架构没有二进制 wheel，且源码无法构建为通过验证的纯 Python 通用 wheel。
- requirements 依赖闭包不完整或版本不匹配。
- 依赖只发布在未配置的私有或专用索引中。
- 插件依赖 CUDA、GPU 驱动、编译器或操作系统动态库；这些不属于 Python wheelhouse。
- requirements 或 pyproject 任一适用路径无法完全离线解析。
- Dify CLI 打包失败。
- 最终包缺少 `requirements.txt`、`uv.toml` 或 wheel。
- ARM64 包中发现 x86_64 wheel。

每次运行使用独立临时目录，不会复用上一次构建留下的 wheel。

## 作者文章

[Dify 纯内网插件离线安装支持多平台多架构跨架构](https://www.cnblogs.com/xjl456852/p/18865586)
