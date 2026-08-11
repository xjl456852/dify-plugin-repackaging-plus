# Dify 插件离线打包自愈设计

## 目标

在不修改打包机 Python、pip 或 Conda 环境的前提下，自动处理 SOCKS 代理下 pip 缺少 PySocks 导致的依赖下载失败。同时提升运行时 Python 版本识别和失败诊断能力，使原本正常的插件保持原流程，能安全自动修复的问题无需人工介入，无法安全修复的问题明确失败且不生成残缺离线包。

## 安全边界

- 不向系统 Python、虚拟环境或 Conda 环境永久安装任何包。
- 不禁用用户代理，也不把 SOCKS 地址猜测为 HTTP 地址。
- 不尝试跨架构编译源码包。
- 不安装 CUDA、GPU 驱动、编译器或操作系统动态库。
- 不在验证失败后生成或保留离线输出包。
- 自动修复仅使用本次构建的 staging 目录，并随 staging 一起清理。

## SOCKS 代理自愈

### 触发条件

依赖下载前检查 `http_proxy`、`https_proxy`、`all_proxy` 及对应的大写变量。任一有效值使用 `socks4://`、`socks4a://`、`socks5://` 或 `socks5h://` 时，认为 pip 需要 SOCKS 支持。

脚本使用已经解析出的 pip 命令执行本地能力检查。若其环境已经安装 PySocks，继续现有下载流程，不创建 bootstrap 目录。没有 SOCKS 代理时也完全跳过该能力检查和自愈流程。

### 临时补齐流程

当 SOCKS 代理存在且 pip 环境缺少 PySocks 时：

1. 使用系统 `curl` 访问当前 `PIP_MIRROR_URL` 的 PySocks PEP 503 simple 页面。curl 原生处理 SOCKS，不依赖 Python 的 PySocks。
2. 从索引中选择固定兼容版本 `PySocks==1.7.1` 的 `py3-none-any` wheel，并解析相对或绝对下载地址。
3. 将 wheel 下载到 staging 下独立的 bootstrap 目录；若索引提供 SHA-256 fragment，则下载后校验摘要。
4. 使用已解析的 pip 命令执行本地、无索引、无依赖的 `--target` 安装。该命令临时移除六个代理环境变量，确保安装过程不会尝试联网。
5. 仅在随后执行 `pip download` 时把 bootstrap 目录加入 `PYTHONPATH`，使 pip 的 SOCKS 适配器可以导入 `socks`。
6. 如果 pip truststore 与 SOCKS 连接池组合精确报出 `key_proxy_ssl_context`，保留首次错误并使用 `PIP_USE_DEPRECATED=legacy-certs` 重试一次。其他错误不触发该兼容回退。
7. 构建成功或失败后均由既有 staging 清理机制删除 bootstrap 文件。

如果 simple 索引中没有兼容 wheel、curl 下载失败、摘要不匹配或本地安装失败，脚本停止并输出一条聚焦的错误信息，说明自动补齐 PySocks 失败以及使用的镜像地址。不会回退直连，也不会修改用户环境。

通过 `DIFY_AUTO_FIX_SOCKS=0` 可以关闭自动补齐。关闭后，检测到缺少 PySocks 时立即给出安装提示并失败。

## Python 版本识别

Python 版本按下列优先级确定：

1. `DIFY_PYTHON_VERSION` 显式覆盖。
2. `manifest.yaml` 中 `meta.runner.version`。
3. `.python-version`。
4. `pyproject.toml` 中 `requires-python` 可识别的最低主次版本。
5. 默认 Python 3.12。

`manifest.yaml` 是 Dify 实际启动插件运行器时使用的元数据，因此优先于开发环境文件。解析器只接受明确的 CPython 主次版本或补丁版本，例如 `3.12`、`3.12.7`；无法识别的值继续尝试下一来源。现有插件没有 manifest 或 manifest 未声明 runner 版本时，保持原回退行为。

## 下载失败诊断

目标平台的单次 `pip download` 仍启用 `--only-binary=:all:`，不增加主机架构回退或源码回退。失败时在保留 pip 原始输出之外补充：

- 目标 Python、ABI、CPU 架构和允许的平台标签。
- 当前镜像地址。
- 常见不可自动修复原因：目标平台无 wheel、依赖仅在额外索引发布、版本约束冲突或代理不可达。

这类失败必须返回非零状态，并由现有清理逻辑移除未完成的输出。

## 代码结构

`plugin_repackaging.sh` 增加小型、可独立测试的函数：

- 判断环境中是否存在 SOCKS 代理。
- 检查选定 pip 是否具有 PySocks。
- 从 simple 索引解析固定 PySocks wheel。
- 在 staging 中准备临时 SOCKS 支持。
- 从 manifest runner 元数据读取 Python 版本。

`download_wheels` 接收本次构建的 bootstrap 目录，在需要时准备临时支持，并仅为真实下载命令注入 `PYTHONPATH`。调用方显式传入位于 staging 根下的目录，避免任何临时文件进入插件输出包。

`plugin_repackaging_amd64_to_arm64.sh` 的命令行和职责保持不变。

## 测试

`tests/test_repackaging.sh` 增加以下回归用例：

- 无 SOCKS 代理时不执行 PySocks 检查、curl 或 bootstrap。
- SOCKS 代理存在且 PySocks 已可用时直接下载。
- SOCKS 代理存在且 PySocks 缺失时，从假 simple 索引下载 wheel、执行本地 target 安装，并通过临时 `PYTHONPATH` 完成下载。
- pip 首次报 `key_proxy_ssl_context` 时只重试一次 legacy-certs，其他错误不重试。
- 自动修复关闭、索引缺少 wheel、下载失败和本地安装失败时明确返回非零状态。
- 大小写代理变量和四种 SOCKS scheme 均可识别，普通 HTTP 代理不触发自愈。
- manifest runner 版本优先于 `.python-version` 与 pyproject，显式覆盖仍具有最高优先级。
- manifest 缺失或版本不可识别时保持原回退逻辑。
- pip 下载失败的诊断包含目标 Python、ABI、架构、平台和镜像。
- bootstrap 文件不会进入最终 `.difypkg`，构建结束不遗留 staging。

最终验收包含 shell 语法检查、完整测试套件，以及在当前 WSL `dify-plugin` Conda 环境和 SOCKS 代理配置下重新打包 `yangyaofei-vllm_0.2.3.difypkg`。输出包仍需通过既有离线 requirements 验证和 ZIP 结构检查。

## 文档

README 增加 SOCKS 自愈说明、关闭开关、Python 版本新优先级和无法自动处理的边界。普通命令保持不变，不要求用户预先安装 PySocks。
