# 纯 Python 源码依赖自愈设计

## 背景

离线打包器当前只允许目标 Python 和目标架构可用的二进制 wheel。这一默认策略可以防止在 x86_64 WSL 中误构建或打入无法在 aarch64 Dify 运行的本地扩展，但也会拒绝一类实际可安全移植的依赖：项目仅发布 sdist，源码却是纯 Python，能够构建为 `py*-none-any` wheel。

`database-plus-0.1.0.difypkg` 是当前实例。插件的 `requirements.txt` 包含 `records[all]~=0.6.0`，`records==0.6.0` 无条件依赖 `docopt`，而 `docopt==0.6.2` 在索引中只有 sdist。现有 ARM64 wheel-only 解析因此失败。手工从该 sdist 构建得到的 `docopt-0.6.2-py2.py3-none-any.whl` 可以让原有 Python 3.12/aarch64 完整依赖解析成功。

`postgresql+uxdb://` 是插件运行时支持的数据库连接协议，与本次依赖获取失败无关。本设计不修改插件业务代码或连接协议。

## 目标

- 保持 wheel-only 为正常路径和最终依赖闭包的硬性要求。
- 对没有发行 wheel、但能构建成严格纯 Python 通用 wheel 的 sdist 自动自愈。
- 不修改打包机的系统 Python、虚拟环境或 Conda 环境。
- 不把宿主 x86_64 原生构建产物误装进 aarch64 离线包。
- 使用插件已选择的目标 Python、镜像和代理配置，不写死公共 PyPI。
- 正常插件保持现有流程；可安全自愈的问题无需人工处理；其余问题明确失败。

## 非目标

- 不交叉编译 C、C++、Rust、Fortran 或其他原生扩展。
- 不安装编译器、系统头文件、CUDA、GPU 驱动或操作系统动态库。
- 不为特定包名维护例外表或预制 wheel 清单。
- 不自动改写插件的 `requirements.txt`、extras 或版本约束。
- 不把构建隔离描述成恶意代码安全沙箱。PEP 517 构建会执行第三方源码。

## 与既有安全边界的关系

既有设计规定不回退到 sdist，以避免跨架构编译。本设计只替换该规则中“所有 sdist 均拒绝”的部分：允许在 staging 中尝试构建候选 sdist，但最终仍只接受经过严格验证的纯 Python 通用 wheel。任何原生或平台相关结果继续失败。因此最终离线包的 wheel-only、目标架构安全和不污染宿主环境等边界保持不变。

## 总体流程

1. 按现有逻辑解析目标 Python、ABI、架构、平台、镜像和代理。
2. 从干净的依赖输出目录执行完整的目标平台下载，并继续传入 `--only-binary=:all:`。
3. 下载成功时直接进入现有离线验证，不创建源码构建目录。
4. 下载失败时保留完整输出，仅在 pip 最终明确报告一个无可用分发的 requirement 时考虑源码自愈。
5. 使用相同索引、代理和 requirement 约束，以 `--no-deps --no-binary=:all:` 获取唯一候选 sdist。
6. 在 staging 内的隔离构建环境中用 PEP 517 构建 wheel，不安装到用户 Python 或 Conda 环境。
7. 对构建结果执行纯 Python 通用 wheel 准入检查。通过后存入 staging 下独立的 `built-wheels` 目录。
8. 清空本轮不完整的下载目录，把 `built-wheels` 作为本地 wheel 来源，再次从头执行完整的 `--only-binary=:all:` 解析。
9. 如果下一轮明确暴露另一个仅有 sdist 的纯 Python 依赖，重复步骤 5 至 8。
10. 完整解析成功后执行既有离线 requirements、pyproject 和归档结构检查，再生成 `.difypkg`。

每轮只修复一个 pip 明确报告的 requirement。记录规范化后的包名和约束；相同项再次出现时立即失败。单次打包最多修复 16 项，防止错误解析、循环依赖或索引异常造成无限循环。

## 触发与错误分类

源码自愈默认启用，可通过 `DIFY_AUTO_BUILD_PURE_SDIST=0` 关闭。关闭后保持原有 wheel-only 失败行为和诊断。

只有 pip 最终错误中存在可解析的 `No matching distribution found for <requirement>`，并且同一次输出包含对应的 `Could not find a version that satisfies the requirement` 语义时，才产生候选 requirement。解析结果还必须通过 requirement 语法校验，不能作为 shell 代码或选项重新解释。

候选 requirement 的 sdist 获取是第二层确认：只有使用相同索引能够选出唯一、合法、符合版本和目标 Python 条件的 sdist 时才进入构建。下列情况不触发或终止自愈，并保留原始 pip 输出：

- DNS、连接超时、代理、TLS、认证或索引访问错误。
- 哈希校验失败。
- 无法解析明确的缺失 requirement。
- 版本约束冲突，或索引中连符合约束的 sdist 都不存在。
- 下载到零个、多个、损坏或不支持格式的 sdist。
- 重复修复同一个 requirement，或达到 16 项上限。

所有脚本自产生的代理、索引、sdist 和 wheel URL 日志继续移除 userinfo、query 和 fragment，避免泄露密码或令牌。

## 构建隔离

源码、构建环境、构建缓存和产物候选全部位于本次 staging 中。构建必须使用与插件目标 Python 主次版本一致的解释器和 PEP 517 wheel 接口，并以 `--no-deps` 构建当前候选。优先复用已经可用且版本精确匹配的解释器；否则使用项目已经要求的 uv 在 staging 专属的 Python 安装目录、缓存目录和虚拟环境中准备该版本。uv 无法取得目标解释器时明确失败，不得静默改用打包机的其他 Python 版本。构建系统依赖可通过当前镜像和代理获取；不得写入或安装到调用者的 Conda、venv、用户 site-packages 或系统 site-packages。

构建第三方 sdist 会执行其构建后端及源码，默认启用是用户确认的便利性与风险取舍。该 staging 隔离只保证环境和文件归属，不保证抵御恶意构建代码。关闭开关是需要禁止执行第三方源码时的明确控制手段。

sdist 获取结果必须是 staging 指定目录中的普通 `.tar.gz` 或 `.zip` 文件。归档名、内部元数据和最终 wheel 的规范化项目名及版本必须一致。任何路径穿越、绝对路径、危险链接或模糊多产物结果均拒绝。

## 通用 wheel 准入

构建结果只有同时满足以下条件才可以加入 `built-wheels`：

- 只有一个 wheel 产物，文件名可按 wheel 规范解析。
- wheel 文件名中的项目名和版本与候选 requirement 及 sdist 元数据一致。
- wheel 的每个兼容标签均为 ABI `none`、平台 `any`；不接受 `abi3` 或任何具体平台标签。
- `.dist-info/WHEEL` 中 `Root-Is-Purelib` 为 `true`，所有 `Tag` 同样满足 `*-none-any`。
- `.dist-info/METADATA` 的项目名和版本与文件名一致。
- ZIP 条目不存在绝对路径、父目录穿越、重复危险条目或符号链接。
- 内容中没有 `.so`、`.dll`、`.pyd`、`.dylib` 等原生扩展文件。
- 文件内容扫描不包含 ELF、PE 或 Mach-O 原生二进制标识。

文件名声称 `none-any` 不是充分条件；元数据和内容检查必须全部通过。原生 sdist 可以被构建工具尝试，但其结果会在准入阶段拒绝，绝不会成为完整解析的本地来源。

## 重新解析与最终产物

被接受的 wheel 只进入 staging 下的 `built-wheels`。重试仍使用目标 Python、ABI、架构、平台和 `--only-binary=:all:`，并通过本地 wheel 来源让 pip 统一重新计算完整依赖闭包。不得把新 wheel 直接复制进先前失败留下的不完整依赖集合。

现有离线验证继续作为最终权威检查。最终 `.difypkg` 可以包含自愈生成且已准入的通用 wheel，但不得包含：

- sdist 归档或解压内容。
- PEP 517 构建环境、缓存和日志文件。
- `built-wheels` 目录结构本身。
- PySocks bootstrap 目录。
- 未准入的候选 wheel。
- 宿主 x86_64 原生二进制。

成功、失败和中断路径均复用 staging 清理机制，不在项目或插件目录留下临时构建文件。

## 用户可见行为

普通命令行保持不变。日志在进入自愈时显示：缺失 requirement、目标 Python/ABI/架构、正在获取 sdist、构建结果和准入结论，但敏感 URL 必须脱敏。

失败信息同时包含：

- 原始 wheel-only 解析错误。
- 自愈所处阶段：识别、sdist 获取、构建、准入、重新解析或次数上限。
- 聚焦原因，例如“构建结果包含 ELF 文件”或“wheel 平台标签不是 any”。
- 可使用 `DIFY_AUTO_BUILD_PURE_SDIST=0` 禁用第三方源码执行的提示。

`records[all]` 当前可能产生“未提供 all extra”的 pip 警告；本设计不改写它。只要其真实依赖闭包可以完整解析，该警告不应阻止打包。

## 代码结构

`plugin_repackaging.sh` 增加职责单一、可独立测试的函数，用于：

- 从下载失败输出提取并校验候选 requirement。
- 使用当前 pip、镜像和代理下载单个 sdist。
- 在 staging 中构建单个 wheel。
- 验证 wheel 文件名、WHEEL、METADATA、ZIP 安全属性和原生内容。
- 管理已修复项目集合、固定次数上限和重新解析循环。

现有 `download_wheels` 继续负责一次严格目标平台下载。上层协调函数负责失败分类和重试，使正常路径、SOCKS 自愈、纯 Python sdist 自愈以及最终离线验证保持清晰边界。`plugin_repackaging_amd64_to_arm64.sh` 的参数和职责不变。

## 测试设计

测试以不依赖公网的 fixture 和伪命令为主，覆盖：

- 依赖全有 wheel 时不下载 sdist、不创建构建环境，命令参数与现有行为一致。
- 初次缺少 `docopt` wheel，构建并准入 `docopt-0.6.2-py2.py3-none-any.whl` 后完整解析成功。
- 连续缺少多个纯 Python wheel 时逐项修复并成功。
- 自动构建关闭时不执行任何 sdist 下载或构建。
- 网络、代理、TLS、认证、哈希及依赖冲突错误不误触发。
- 缺失 requirement 无法解析或包含危险选项字符时失败。
- sdist 为零个、多个、损坏、版本不符、路径穿越或危险链接时失败。
- PEP 517 构建失败时保留原始下载错误和聚焦诊断。
- 原生平台 wheel、`abi3` wheel、伪装为 `none-any` 但包含原生扩展或二进制魔数的 wheel 均拒绝。
- WHEEL/METADATA 与文件名的名称、版本或标签不一致时拒绝。
- 同一依赖重复出现和 16 次上限能终止循环。
- 每轮从干净下载目录重新解析，不接受上一轮残缺集合。
- SOCKS 与 HTTP 代理、镜像和敏感 URL 脱敏在 sdist 下载及构建阶段继续生效。
- 完整归档包含准入 wheel，但不包含 sdist、构建目录、bootstrap、缓存或宿主原生文件。
- 任何失败均不生成或保留残缺 `.difypkg`，staging 得到清理。

最终真实验收使用当前 `database-plus-0.1.0.difypkg`，目标为 Python 3.12/aarch64。预期自动修复 `docopt`，完整下载其余 ARM64 依赖，通过既有离线 requirements、pyproject 和 ZIP 结构检查，并生成可供内网 Dify 安装的离线包。

## 文档更新

README 说明纯 Python sdist 自愈的触发条件、默认执行第三方构建代码的风险、关闭开关、严格准入条件和原生扩展仍不支持的边界。示例继续使用现有打包命令，不要求用户预先安装 `docopt` 或修改 Conda 环境。
