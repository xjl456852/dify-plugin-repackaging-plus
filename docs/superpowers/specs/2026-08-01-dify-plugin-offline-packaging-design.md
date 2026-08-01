# Dify 插件双路径离线打包设计

## 目标

将 Dify Python 插件重新打包为自包含离线安装包。输出包不能依赖外部 PyPI、镜像站或 Dify 版本特定的依赖文件优先级；无论插件守护进程选择 `requirements.txt` 还是 `pyproject.toml`，都只能从包内 `wheels/` 解析依赖。

现有两个入口保持兼容：

- `./plugin_repackaging.sh local <plugin.difypkg>`：目标架构默认与打包主机相同。
- `./plugin_repackaging_amd64_to_arm64.sh local <plugin.difypkg>`：在 AMD64 主机上生成 ARM64 依赖包。

脚本作者统一标记为 `xiejianglei`。

## 已确认的根因

1. Dify 1.16.0 使用 `langgenius/dify-plugin-daemon:0.6.3-local`。该 daemon 在 `PIP_MIRROR_URL` 为空且插件同时包含两个依赖文件时优先执行 `uv sync`，所以只修改 `requirements.txt` 无法形成离线包。
2. 原 ARM64 脚本只请求 `manylinux2014_aarch64`。`gevent==26.5.0`、`greenlet==3.5.1` 和 `tiktoken==0.13.0` 的 ARM64 wheel 使用 `manylinux_2_28_aarch64` 等较新标签，因此下载失败。
3. ARM64 下载失败后，脚本不带目标平台参数再次下载，实际得到打包主机的 x86_64 wheel。
4. 逐包下载逻辑只按包名前缀判断是否存在，没有核对版本。例如已有 `idna-3.18` 时会错误跳过要求中的 `idna==3.16`。
5. 下载、依赖处理和最终 package 命令的失败没有被一致传播，脚本可能把不完整 wheelhouse 标记为打包成功。
6. 固定复用解压目录和 `wheels/` 会把上一次运行的 wheel 混入新包。

## 兼容性策略

### 双路径离线元数据

输出包同时支持两类已知的 Dify Python 依赖安装路径：

1. `requirements.txt` 路径：文件开头使用两条独立指令：

   ```text
   --no-index
   --find-links=./wheels
   ```

   `uv pip install -r requirements.txt` 和兼容 requirements 格式的 pip 安装器只能读取包内 wheelhouse。

2. `pyproject.toml` 路径：保留插件的 `[project]` 运行时元数据；从 staging 副本中删除 `[dependency-groups]` 以及旧式 `[tool.uv].dev-dependencies` / `default-groups`，并在 `[tool.uv]` 中写入只匹配目标 Linux、CPU 架构和 Python 版本的 `environments`。包根目录同时生成 `uv.toml`：

   ```toml
   offline = true

   [[index]]
   name = "dify-offline-wheels"
   url = "./wheels"
   format = "flat"
   default = true
   ```

   该配置将本地 wheelhouse 设为 uv 项目的唯一默认索引，并明确禁止网络访问。它不要求修改插件自己的 `[project]` 依赖声明。

原始 `uv.lock` 不进入输出包。锁文件通常记录公网 registry URL，而且 daemon 检测到它后会增加 `--frozen`。删除锁文件后，`uv sync` 会依据运行时规范化后的 `pyproject.toml` 从本地唯一索引重新解析。

`environments` 必须写入 `pyproject.toml`，不能写入 `uv.toml`：真实 uv 验证表明该字段属于项目配置。若不限制解析环境，uv 的通用锁定会继续解析开发组、Windows 和其他 CPU 平台，导致本来完整的 ARM64 运行时 wheelhouse 因无关依赖而失败。

这套策略不读取或判断 Dify 版本。只要安装器继续支持标准 requirements 文件或 uv 项目，两条路径至少有一条可用；当前 daemon 两条路径都能离线解析。如果未来 Dify 引入第三种完全不同的依赖格式，需要为该格式增加适配，但现有打包命令和架构模型无需改变。

### 输入依赖格式

- 存在 `requirements.txt` 时，以它作为下载依赖闭包的权威输入。
- 不存在 `requirements.txt`、但同时存在 `pyproject.toml` 和 `uv.lock` 时，使用 `uv export --frozen` 生成 requirements；导出时排除项目本身、全部默认依赖组、开发组、注释和 hashes。
- 只有 `pyproject.toml` 时，使用非 frozen 的 `uv export` 在线解析并生成 requirements。
- 两种依赖文件都不存在时，将插件视为无第三方 Python 依赖；仍生成空的离线 `requirements.txt` 和 `uv.toml`，以避免安装器尝试猜测远程来源。
- 需要从 pyproject 导出但系统找不到 `uv` 时，立即失败并给出安装提示。

### Python 与平台选择

打包目标和运行打包器的主机架构分开处理：

- 主机架构只决定运行 `dify-plugin-linux-amd64-5g` 还是 `dify-plugin-linux-arm64-5g`。
- 目标架构决定下载哪一种 wheel。统一入口默认使用主机架构，ARM64 兼容入口设置目标为 `aarch64`。
- Python 版本优先读取插件的 `.python-version`，其次读取可明确解析的 `requires-python` 下限，最后回退到 Dify 当前通用的 `3.12`。可以使用 `DIFY_PYTHON_VERSION` 显式覆盖，但正常使用不要求了解 Dify 版本。
- CPython ABI 从目标 Python 主次版本生成，例如 Python 3.12 对应 `cp312`。
- glibc Linux 默认同时允许 `manylinux_2_28_<arch>` 和 `manylinux2014_<arch>`。可通过面向高级场景的环境变量覆盖平台列表，而无需修改脚本。
- 只允许 wheel，不允许 sdist。缺少目标架构二进制 wheel 时构建失败，避免在纯内网生产环境中临时编译。

## 数据流

1. 校验命令参数、源 `.difypkg`、`curl`、`unzip`、Python/pip、uv 和对应主机架构的 Dify 打包二进制。
2. 在项目目录下创建唯一临时 staging 目录，解压源包；不复用以前的解压目录。
3. 规范化依赖输入：必要时从 uv 项目导出 requirements，并生成一份不包含旧离线索引指令的下载输入文件。
4. 创建全新的 `wheels/`，用一次完整的目标平台 `pip download` 解析并下载全部固定依赖闭包。禁止逐包回退和主机平台回退。
5. 写入双路径离线配置；规范化 staging 中的运行时 `pyproject.toml`，移除开发组并限制 uv 目标环境；移除 `uv.lock`，并确保 `.difyignore` 不排除 `wheels/` 或 `uv.toml`。
6. 在目标 Python/平台条件下执行不联网的 requirements dry-run；输入包含 `pyproject.toml` 时再执行 `uv sync` dry-run。任何适用路径尝试联网、缺少版本或没有兼容 wheel都会停止构建。
7. 调用与主机架构匹配的 Dify CLI 生成 `*-offline.difypkg`。
8. 检查最终 ZIP：必须包含 wheel、`requirements.txt` 和 `uv.toml`，不能包含 `uv.lock`；随后报告输出路径。
9. 只清理由本次运行创建且路径经过校验的 staging 目录。源包和输出包不参与清理。

## 脚本结构

`plugin_repackaging.sh` 成为唯一实现，负责三种来源模式、依赖规范化、目标平台下载、双路径配置、验证和打包。

`plugin_repackaging_amd64_to_arm64.sh` 保留原命令行接口，只设置 ARM64 目标并把所有参数传给统一脚本。这样两个入口不再复制依赖处理代码，后续修复不会再次分叉。

`tests/test_repackaging.sh` 使用临时 fixture 和 PATH 中的假 `pip`/打包器测试参数与控制流；能使用本机 uv 的集成测试则验证真实的离线解析。测试脚本不依赖 Bats 等额外框架。

## 错误处理

- 脚本启用严格错误传播；管道中任一步失败都会返回非零状态。
- `curl` 使用 HTTP 失败感知选项，避免把 404 页面当插件包。
- 所有路径均加引号，支持空格；源路径通过 `realpath` 解析并验证。
- 下载失败时打印目标 Python、ABI、平台列表和 pip 的原始错误，不再静默重试另一架构。
- 离线验证失败时明确指出失败的是 requirements 路径还是 uv 项目路径。
- 打包二进制失败或最终包结构校验失败时，不打印“成功”。

## 测试与验收

自动化测试覆盖：

- ARM64 入口把目标架构传给统一实现，同时仍选择 AMD64 主机打包器。
- ARM64 下载命令包含 Python/ABI、`manylinux_2_28_aarch64`、`manylinux2014_aarch64` 和 `--only-binary=:all:`，且不存在无平台回退。
- 原始问题中的 requirements 不会因其他版本的同名 wheel 被误判为完整。
- 输出 requirements 的离线指令独立、幂等，`wheels/` 和 `uv.toml` 不会被 `.difyignore` 排除。
- 输入含 `pyproject.toml` 时输出包继续保留它；所有输出包包含 `uv.toml` 且不含 `uv.lock`。
- 新旧 uv 开发依赖配置均不会进入运行时解析，已有 `[tool.uv]` 的其他设置保持不变，目标环境不会重复写入。
- pip 下载失败、requirements dry-run 失败、uv dry-run 失败及 Dify CLI 失败都会令整个命令失败。
- 只有 pyproject/lock 的插件可以导出 requirements；缺少 uv 时得到明确错误。
- 含空格的本地源路径可正确处理。
- 两次构建不共享 staging 或 wheel。

针对用户提供的 `langgenius-openai_api_compatible_0.0.57.difypkg` 做端到端验收：

- 目标 ARM64 wheelhouse 中不得出现 x86_64 wheel。
- 必须包含固定版本的 `pyyaml==6.0.3`、`gevent==26.5.0`、`greenlet==3.5.1`、`tiktoken==0.13.0`、`idna==3.16` 等依赖。
- 使用 `uv 0.11.24` 对 ARM64/Python 3.12 执行 requirements 和 pyproject 两条离线 dry-run 均成功。
- 最终 `.difypkg` 通过结构检查；若本地 Docker 可用，再在 `langgenius/dify-plugin-daemon:0.6.3-local` 的 ARM64 环境中执行等价的无网络解析验证。

## 文档更新

README 将说明：

- 打包机需要可用的 Python/pip、uv、curl 和 unzip。
- 普通入口与 AMD64 到 ARM64 入口的示例保持不变。
- 默认自动读取插件 Python 版本，不要求填写 Dify 版本。
- 仅在非标准 Python 或 manylinux 环境下才需要使用高级覆盖变量。
- 构建遇到目标平台没有 wheel 时会失败，这是为了保证输出包可以真正离线安装。
