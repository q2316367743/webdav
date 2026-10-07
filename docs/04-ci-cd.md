# CI / CD：测试与发布工作流

本模块的持续集成与发布全部放在 `.github/workflows/` 下：

| 文件 | 触发 | 职责 |
|------|------|------|
| `ci.yml` | `push master`、`pull_request`、手动 | 检查 → 构建 → 单元与黑盒测试 → 门禁；另起 job 跑真实服务端全流程 |
| `publish.yml` | Release（`released`）、手动 | 校验 tag 与版本 → 门禁 → `moon publish` 到 mooncakes.io |
| `copilot-setup-steps.yml` | 自身变更、手动 | 仅用于 Copilot 编码代理的环境预装，与 CI / 发布无关 |

## ci.yml

两个 job 并行、无 `needs`，便于独立重跑并区分「单元失败」与「端到端失败」；
顶层 `permissions: contents: read`，`concurrency` 按分支取消旧任务。

### job `check-build-test`（20 分钟超时）

| 步骤 | 命令 | 失败含义 |
|------|------|----------|
| 安装 | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash`，并把 `$HOME/.moon/bin` 写入 `$GITHUB_PATH` | 工具链下载失败 |
| 版本 | `moon version --all` | 记录 moon / moonc / moonrun 版本，便于回溯 |
| 依赖 | `moon update` | mooncakes 依赖解析 / 下载失败（实测不会弄脏 tracked 文件） |
| 检查 | `moon check --deny-warn` | 类型错误，**或任何告警**（告警按错误处理） |
| 构建 | `moon build` | native 编译 / 链接失败 |
| 测试 | `moon test` | 单元与黑盒测试失败（Mock 传输层，不触网） |
| 门禁 1 | `moon info` 后 `git diff --exit-code` | 公开 API 变了却没提交重新生成的 `.mbti` |
| 门禁 2 | `moon fmt --check` | 代码未格式化（`--check` 只检查，不改文件） |

### job `e2e`（20 分钟超时）

只跑一条命令：`bash src/main/run_tests.sh`。该脚本是仓库里唯一的一键测试入口：

1. 起 WebDAV 服务端——优先 brew 的 `webdav`，CI 上没有，于是回退
   `src/main/testdata/verify_server.py`，并设 `VERIFY_NO_HEAD_PREFIX=/demo`
   覆盖客户端「HEAD 不支持 → PROPFIND `Depth:0` 回落」分支；
2. `moon test`（66 个用例）；
3. `moon run src/main` 连真实服务端跑完整流程（上传 / 下载 / MOVE / COPY /
   PROPPATCH / 特殊文件名 / 本地路径流式往返）；
4. 关闭服务端并汇总，退出码 0 表示两阶段全过。

脚本的阶段判定是「子进程退出码 + 输出标记」双条件：只看输出里的 `✓` / `✗`
会把编译失败（输出里没有标记）误判成通过，这也是 CI 能信任该 job 的前提。

## publish.yml

### 触发条件

- 发布正式 Release（`release: types: [released]`）；
- Actions 页手动触发（`workflow_dispatch`）。

**不会触发**的情形：仅推送 tag、把 Release 存成 Draft、勾了 pre-release。

### 步骤

1. `校验 tag 与 moon.mod 版本一致`（仅 Release 事件）：从 `moon.mod` 抓
   `^version`，与 `github.event.release.tag_name` 去 `v` 前缀后比对，不一致用
   `::error::` 输出中文指引并立刻失败，不触注册表。
2. 安装 MoonBit、`moon version --all`、`moon update`。
3. 发布前门禁：`moon check --deny-warn` → `moon info` + `git diff --exit-code`
   → `moon fmt --check` → `moon test`，任一步失败都不发布。
4. 把 `secrets.MOONCAKES_TOKEN` 写成 `~/.moon/credentials.json` 后执行
   `moon publish`；随后由 `if: always()` 的步骤删除该文件。

不在发布前重跑端到端流程：发布流程本身要求「该提交的 CI 已全绿」，端到端已在
`ci.yml` 的 `e2e` job 覆盖，重复冷编译没有额外收益。需要更强保证时在
`.github/workflows/publish.yml` 的门禁后加一行 `bash src/main/run_tests.sh` 即可。

### 一次性配置（仓库管理员）

1. 本机 `~/.moon/credentials.json` 是登录 mooncakes.io 后的凭据，内容为一行 JSON：
   `{"token": "<你的 token>", "username": "q2316367743"}`。
2. 仓库 `Settings → Secrets and variables → Actions → New repository secret`，
   名称 `MOONCAKES_TOKEN`，值填上面**完整的一行 JSON**。
3. 没有这个 secret 时，Release 触发的发布会在「发布到 mooncakes.io」一步失败，
   其余步骤不受影响。

### 发布一个新版本

1. 改 `moon.mod` 的 `version`（例如 `0.1.0` → `0.2.0`），提交并推送到 master；
2. 等这次 push 的 CI 跑绿；
3. 仓库页 → Releases → Draft a new release，Tag 输入 `v0.2.0`（target: master），
   不勾 pre-release、不存 Draft；
4. 点 Publish release，工作流自动发布。

mooncakes.io 上的版本号取自 `moon.mod` 的 `version`，GitHub tag 只是标记。

## 已知注意事项

- **仅 native 后端**：`moon.mod` 的 `preferred_target = "native"`（moonhttp 依赖
  `moonbitlang/async`，wasm/js 上异步仍是实验性的），因此 CI 不做跨后端矩阵。
  native 目标需要 C 编译器，ubuntu-latest 自带。
- **无需额外系统库**：`moonbitlang/async` 的 TLS 用 `dlopen` 动态加载 OpenSSL，
  没有链接期 `libssl` 依赖，而本模块的测试全部走 HTTP。若将来测试 HTTPS 且
  运行器报 TLS 加载失败，再加 `sudo apt-get install -y libssl-dev`。
- **`moon publish --dry-run` 不能当门禁**：它需要凭据，而且即便输出
  `Server status: 202 Accepted, detail: Dry run completed successfully.`，
  当前工具链仍以退出码 255 结束（`Error: \`moon publish\` failed`）。它只适合在
  有凭据的本机做人工预检。
- **发布包不含 `src/main`**：`.moonignore` 里写了 `src/main`，它控制的是打包内容
  （`moonignore` 的语义即「哪些文件会被打包」），演示程序与 testdata 不进发布 zip；
  `moon check` / `moon test` 仍覆盖该包。
- **超时**：两个 job 都是 20 分钟。首次冷编译 native 依赖通常远低于此；若逼近上限，
  再统一放宽并考虑给 `~/.moon` 加缓存。
- **macOS 自带 bash 3.2 的坑**：`$VAR` 后面紧跟全角字符（如 `$STATUS）`）时，3.2 会把
  多字节字符的首字节吞进变量名，配合 `set -u` 直接报 `unbound variable` 并终止脚本。
  改 `run_tests.sh` 时，变量后紧跟中文/全角字符必须写成 `${VAR}`（脚本里已有此先例，
  例如 `${SERVER_KIND}）`）。

## 本地复现

```bash
bash src/main/run_tests.sh          # 端到端：起服务端 → moon test → 真实全流程
moon check --deny-warn              # 检查（等价 CI 检查步骤）
moon fmt --check                    # 格式门禁（只检查、不改文件）
moon info && git diff --exit-code   # .mbti 门禁
moon publish --dry-run              # 发布预检（需本机凭据；注意退出码 255 属正常）
```
