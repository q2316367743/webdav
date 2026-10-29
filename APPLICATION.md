## WebDAV 客户端项目申报书

### 基本信息

| 项目 | 内容 |
|------|------|
| 项目名称 | webdav |
| 参赛者 | q2316367743 |
| 联系方式 | 17762618644 |
| GitHub 仓库链接 | <https://github.com/q2316367743/webdav> |
| 模块 / 版本 / 许可 | `q2316367743/webdav` / 0.1.0 / Apache-2.0 |
| 项目方向 | MoonBit 网络协议基础库 / 文件同步基础设施 |


### 项目简介

`webdav` 将 WebDAV 协议（RFC 4918）的核心客户端能力带入 MoonBit 生态，为需要在 MoonBit 中接入云存储、实现文件同步、或构建网盘客户端工具的开发者提供类型安全、异步原生的 WebDAV 客户端库。库默认基于参赛者自研并发布于 mooncakes 的 moonhttp HTTP 客户端执行请求，执行层亦可通过 `Transport` 接口整体替换（moonhttp 依赖 moonbitlang/async 运行时，当前仅支持 native 后端，Wasm 支持随依赖生态演进列为后续方向）。项目面向三类使用者：**需要对接 Nextcloud/ownCloud 的 MoonBit 应用开发者**、**构建文件同步工具的 CLI 作者**、以及**在服务器端脚本与本地自动化任务中需要轻量级远程文件操作的场景**。

WebDAV 是文件同步和网盘接入领域的事实标准协议，Nextcloud、ownCloud、Apache mod_dav、SabreDAV 等主流服务端均以其为基础。MoonBit 生态中原有的 DAV 相关工作集中在**协议语义层**（构造请求、解析响应，网络与文件 IO 交由宿主语言完成）。`webdav` 的定位与之互补：**在 MoonBit 内完成网络执行的完整客户端**——协议构造、XML 解析、真实 HTTP 收发、流式传输、锁闭环与错误分类全部由 MoonBit 侧承担，下游开发者无需自行编写 HTTP 请求、XML 解析与 207 Multi-Status 处理逻辑。

### 核心功能范围

**本期交付范围（RFC 4918 核心，逐章节对照与案例见 `docs/08-rfc4918-scope.md`）：**

- **HTTP 方法封装**：PROPFIND（`list` / `list_recursive` / `stat` / `get_properties(_with_status)`）、PROPPATCH（`set_properties`）、MKCOL（`mkdir` 单级 / `mkdir_all` 逐级递归）、GET（`get_file` 全量 / `download_file` 分块回调 / `download_to_path` 流式写盘）、PUT（`put_file` 内存字节 / `put_file_stream` 任意读取流 / `put_file_from_path` 本地文件路径）、DELETE、COPY/MOVE（`copy_path` / `move_path`，`overwrite` 与 `Depth`）、LOCK/UNLOCK（`lock` 独占与共享 / `refresh_lock` / `unlock` / `get_locks` 读 `lockdiscovery` / `cleanup_lock_null` 收尾 §7.3 空资源）、OPTIONS（`options` 读 `DAV` / `Allow` / `Server`）
- **传输能力**：上传三形态均为流式发送（定长或 chunked），下载三形态共用分块循环；上传 / 下载均有进度回调（`Progress.percent()`）；全部网络方法支持 `conditions?`（`If-Match` / `If-None-Match` / 锁令牌 / 完整 `If` 列表）与 `signal?` 取消（`AbortSignal`）
- **Range 与断点续传（RFC 7233）**：三个下载方法均支持 `range? : ByteRange`（206 / 200 双状态、`Content-Range` 解析）；`download_to_path_resume` 以本地残留为起点续传——206 追加 / 200 回退重写 / 416 且已下完视为成功，`etag?` 发 `If-Range` 防服务端文件已变
- **Multi-Status 响应解析**：`207` 的 `response` / `href` / `propstat` / `status` / `responsedescription` 解析为 `ParsedResource` 并映射为 `FileInfo` / 属性表；**propstat 状态逐段归属**，因此「属性不存在（404）」与「属性值为空」可区分；DELETE / MOVE / COPY 的 207 部分失败汇总为 `WebdavError::Partial`，不再当成功
- **属性系统**：PROPFIND 的 `allprop` 与指定属性两种模式，解析标准 DAV 属性（`getcontentlength`、`getlastmodified`、`getetag`、`resourcetype`、`getcontenttype`、`creationdate` 等）；PROPPATCH 在自定义命名空间下设置属性
- **锁与条件**：独占与共享写锁、锁令牌归一（`tok` / `<tok>` 等价）、完整 `If` 渲染（列表内合取、列表间析取、`Not`、`[etag]`、带标签列表）并在发包前做四类本地校验；可选 `retry_on_423` 在收到 423 时按进程内锁注册表补令牌重试一次
- **健壮性**：路径 percent 编解码与 `href` 归一（绝对 URL、带 query 的 href 均可正确排除自身与取显示名）；`exists` 在服务端禁用 HEAD 时回退 PROPFIND；本地文件形态保障（先请求后建文件、句柄必关、失败残留可续传）
- **统一错误**：`WebdavError` + `detail()` 六分类（网络 / XML / 非期望状态码 / 207 部分失败 / 已取消 / 本地文件），`Api` 消息附中文注解与响应体摘要
- **认证支持**：Basic Auth（用户名 / 密码，均缺省时不携带认证头）

**明确不做的内容：**

- CalDAV（RFC 4791）与 CardDAV（RFC 6352）
- RFC 3253 版本控制、RFC 3744 ACL、RFC 5323 搜索、RFC 6578 Sync Collection
- POST；`allprop + include`；PROPPATCH 的 `<D:remove>`（只做 `set`）
- Digest 认证（列在 `docs/03-gap-analysis.md` 的 P1 候选）
- 多区间 `Range` 与 multipart/byteranges；`>2GB` 资源的区间端点（受 `Int32` 约束）
- Wasm 后端（moonhttp 依赖 moonbitlang/async 异步运行时，当前仅 native）


### 与同生态实现的关系（复用边界）

本仓与 `liu-fang38/webdav`（同为 MoonBit WebDAV 实现）**不存在复用关系**：两边无共同提交历史（本仓 15 次提交自 2026-10-05 起，对照仓 33 次提交自 2026-09-10 起，布局 / 作者 / 工具链均不同）；本仓依赖只有 moonhttp、`Milky2018/xml`、`moonbitlang/async`，源码与依赖清单检索 `liu-fang38` 零命中；重合度经脚本量化（`tools/similarity_check.py`）：源码同规模 8-gram Jaccard 最高 2.96%、远端 8-gram 反向覆盖率 2.38%、**最长连续公共片段 25 个 token（内容为 XML 声明字面量）**、文档 14-gram 最高 0.69%。表面「协议核心重叠」来自 RFC 4918 规定的字面量（方法名、`DAV:` 元素名、头名、状态码），任何合规实现都必然相同。

**职责划分不同**：对照包在 MoonBit 侧只构造请求记录与解析响应（其 `pkg.generated.mbti` 仅 16 个顶层非 async 纯函数，HTTP(S)、Digest 与文件 IO 由 Node 宿主承担）；本仓的 MoonBit 侧就是客户端本身，在 MoonBit 内完成网络执行、流式传输、续传状态机与锁闭环。逐项对照、13 项新增职责清单与边界声明见 `docs/07-reuse-boundary.md`。

**对方所长（本仓未做）**：Digest 认证、TLS 信任链三种场景的专项用例、150 条 XML 参考向量对照。本仓认证目前只有 Basic。


### RFC 4918 兼容范围

逐章节对照（§4.4、§5.2、§6.7–§6.8、§7.3、§7.5、§7.7、§8.2–§8.3、§8.6、§9.1–§9.11、§10.1–§10.7、§11.1、§15）与「部分实现 / 明确不做」清单见 `docs/08-rfc4918-scope.md`。范围判据是「本仓公开 API 是否实现该章节要求的行为」，不以服务端是否配合为准——服务端不支持的能力按预期软跳过并如实记录。

### 验收产物

- `q2316367743/webdav` 库（v0.1.0，Apache-2.0），可通过 `moon add q2316367743/webdav` 引入
- **核心 API 可运行**：`create_webdav_client` → `mkdir_all` / `put_file` / `list` / `download_to_path` / `lock` / `unlock` → Multi-Status 解析 → 统一错误分类的完整链路
- **测试覆盖**：**164 个用例全部通过**（`moon test`：MockTransport 注入 200/201/204/206/207 及 404/405/409/412/416/423 等响应，不触网，断言请求方法 / 头 / URL 编码 / body 形状与错误分支）
- **端到端演示**：`bash src/main/run_tests.sh` 自动启动真实 WebDAV 服务端（优先 hacdias/webdav，回退自带 Python 兜底服务端）并跑完整流程，2026-10-16 实测 PASS，覆盖：多级中文路径递归建目录与幂等重跑、上传（含 100 KiB 本地文件路径形态与进度）、流式下载、**区间 206**、**断点续传拼接比对**、移动 / 复制 / 删除、特殊文件名往返、OPTIONS 能力探测、`exists` 的 HEAD 回退、**LOCK → 无令牌 PUT 被拒 423 → 带令牌 PUT → 刷新 → UNLOCK**、lock-null 清理、423 自动补令牌重试；服务端不支持的能力（hacdias 的共享锁 501、带标签 `If` 412）按预期软跳过，由自带 Python 兜底服务端覆盖
- **文档**：`README.mbt.md`（安装、快速上手、功能一览、已知限制）与 `docs/` 八篇技术文档（01 架构与协议映射、02 API 参考、03 缺口分析与路线图、04 CI / CD、05 锁能力扩展、06 Range 与断点续传、07 复用边界与 native 新增职责、08 RFC 4918 兼容范围与案例）

### 移植或参考说明

| 项目 | 说明 |
|------|------|
| **参考项目 1** | `d-k-bo/webdav-rs`（Rust，Apache-2.0/MIT 双许可） |
| **参考项目 2** | `perry-mitchell/webdav-client`（TypeScript，MIT） |
| **参考项目 3** | `io-webdav` 的 RFC 模块化组织方式（按 RFC 拆分源代码树） |
| **同生态对照** | `liu-fang38/moonbit-webdav`（协议语义层 + Node 宿主）、`justinwongcn/moon-ical`（含最小 CalDAV 服务端）|
| **本项目许可证** | Apache-2.0（与参考项目兼容） |

**参考范围说明：**

- **webdav-rs**：参考其“类型定义与 HTTP 执行层分离”的设计——协议层只生成请求对象、解析响应，不绑定特定 HTTP 客户端。本库落地为：WebDAV 协议逻辑与执行层（`Transport` 接口）分离，默认执行层复用参赛者已有的 MoonBit HTTP 客户端 moonhttp，测试中以 MockTransport 注入
- **webdav-client**：参考其方法签名设计和配置选项组织方式（`createClient(url, options)` 风格对应本库的 `create_webdav_client(WebdavConfig)` 结构体配置 + 命名参数方法）
- **XML 解析依赖**：选用 mooncakes 上的 `Milky2018/xml`（命名空间感知的 Reader / Writer）。本库在其上构建 DAV 专属的 XML 序列化 / 反序列化层（`xmlutil` 包）
- **与同生态实现**：无代码复用、无依赖关系，仅作为生态现状与差异化定位的对照对象；量化证据与逐项对照见 `docs/07-reuse-boundary.md`

**与参考项目的差异：**

- 使用 MoonBit 原生类型系统表达 WebDAV 语义：Multi-Status 条目解析为 `FileInfo` / 属性表，而非动态语言的对象映射
- 错误以单构造器 `WebdavError` 包装分类枚举 `WebdavErrorDetail`（六类），调用者模式匹配时必须显式处理每一类
- 执行层可插拔：默认 moonhttp，亦可通过 `create_webdav_client_with_transport` 注入任意 `Transport` 实现
- 在参考项目之外补齐了传输形态（上传 / 下载各三形态）、Range 与断点续传、锁闭环（共享锁 / 完整 `If` / lock-null / 423 重试）与递归建目录

### 复核方式

```bash
bash src/main/run_tests.sh                 # 164 用例 + 真实服务器全流程
grep -rn "liu-fang38" src moon.mod         # 零命中（源码与依赖清单无引用）
python3 tools/similarity_check.py          # 重合度四指标，可复现
```
