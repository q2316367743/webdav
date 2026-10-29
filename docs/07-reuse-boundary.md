# 与同生态 WebDAV 实现的复用边界，及 native 集成的新增核心职责

本文档答复赛事初审意见「与 liu-fang38/webdav 的协议核心重叠」的前两问：
**复用边界是什么**、**native 集成带来了哪些新增核心职责**。
RFC 4918 兼容范围与案例见 `docs/08-rfc4918-scope.md`。

- 本仓基准：提交 `43b2eca`（版本 0.1.0，工具链 moon 0.1.20261012），观测日 2026-10-16
- 对照对象：`liu-fang38/moonbit-webdav` @ `main`（其申报版本 `liu-fang38/webdav` 0.4.2，
  2026-09-28 上架 Mooncakes，GitHub 仓库 2026-09-19 创建、2026-09-30 最后推送）

## 0 三问三答

| 初审问题 | 答复 | 证据位置 |
|----------|------|----------|
| 复用边界 | **无复用关系**：无共用版本历史、无代码依赖、无成规模代码或文档重合；表面重叠部分全部来自 RFC 4918 的规范用语 | 本文第 1、2 节 |
| native 集成的新增核心职责 | 本仓在 MoonBit 内承担**真实网络执行层与传输形态**等 13 项职责，对照包在 MoonBit 层**不发起任何网络请求**（其网络、认证与文件 IO 由 Node 宿主承担） | 本文第 3、4 节 |
| RFC 4918 最终兼容范围 | 逐章节声明「已实现 / 明确不做」，并附当次可复现案例 | `docs/08-rfc4918-scope.md` |

## 1 复用边界：三项独立证据

### 1.1 无共用版本历史

两边都保留完整 git 历史，作者、布局、工具链均不同：

| 维度 | 本仓 | 对照包 |
|------|------|--------|
| 首次提交 | 2026-10-05「初始化」 | 2026-09-10「Import independently verified local candidate baseline」 |
| 提交数 / 作者 | 15 次，作者 `落雨不悔` | 33 次，作者 `liu-fang38` 与 `Codex` |
| 目录布局 | `src/{types,xmlutil,client,main}` 多包 + `source = "src"` | 仓库根单包 + `cmd/` + `tools/` + `web/` |
| 目标后端 | native（`preferred_target = "native"`） | JS / Wasm-GC |
| 许可 | Apache-2.0 | MIT |

两仓不存在共同祖先提交，也不存在 fork 关系（对照仓 `fork = false`，无 `parent`）。

### 1.2 无代码依赖

- 本仓 `moon.mod` 的依赖只有三项：`q2316367743/moonhttp`、`Milky2018/xml`、`moonbitlang/async`，
  不含 `liu-fang38/webdav`；
- 源码与依赖清单（`src/`、`moon.mod`、`moon.pkg`、`README.mbt.md`）检索 `liu-fang38`
  **零命中**，即本仓从未引用、复制或链接对方代码（本文档与 `docs/08-rfc4918-scope.md`
  为答复初审意见而提及对方仓库名，属说明性引用，不构成依赖）；
- 对照包的 `pkg.generated.mbti` 只 import `moonbitlang/core/debug`，同样不依赖本仓。

### 1.3 无成规模代码 / 文档重合（可复现量化）

复核命令（本仓自带脚本，联网拉取对照仓快照后比对）：

```bash
python3 tools/similarity_check.py
```

2026-10-16 当次运行结果：

| 指标 | 结果 |
|------|------|
| 源码 8-gram Jaccard 全量最高 | 6.50%（`usability.mbt` 193 token ↔ `src/xmlutil/propfind.mbt` 264 token，小分母放大的小文件对） |
| 源码同规模子集最高（两侧均 ≥400 token） | 2.96%（`authoring_test.mbt` ↔ `src/client/lock_ops_test.mbt`） |
| 反向覆盖率（远端 12332 个 8-gram 中出现在本仓的比例） | 2.38% |
| **最长连续公共片段** | **25 个 token**，内容为 XML 声明字面量 `= "<?xml version=\"1.0\" encoding=\"utf-8\"?>` |
| 文档 14-gram 最高 / 反向覆盖率 | 0.69% / 0.70% |

关于文档指标的说明：本文档与 `docs/08-rfc4918-scope.md` 为答复初审意见，必然引用对照包的
仓库名与其自述用语（如「不提供断点续传」），这会把文档指标相对答复前的快照（0.71% / 0.35%）
略微抬高——两个口径均远低于判定阈值，此处如实列出两个口径以便复核。

共享片段的抽样（逐字摘录）显示其性质为 XML 语法与协议词汇，而非实现逻辑：

```
" ) , Some ( " ( <        " < D : multistatus xmlns : D      " < D : prop xmlns : D
< D : propstat > < D :    < D : status > HTTP / 1            < D : write / > < /
Depth                      If                                 Lock - Token
```

方法说明与局限：8-gram 只能判断「连续片段是否雷同」，擅长证伪成规模复制，
不构成「绝无借鉴」的证明；`PROPFIND`、`DAV:`、`propstat`、`If-Match`、`207`
等是 RFC 4918 规定的字面量，任何合规实现都必然相同，不影响结论。

### 1.4 为什么「协议核心」看起来重叠

同一协议下，两边的**功能名、XML 元素名、头名、状态码**必然一致；差异在实现来源与
职责划分。逐项对照：

| 同一件事 | 对照包的实现位置与形态 | 本仓的实现位置与形态 |
|----------|------------------------|----------------------|
| PROPFIND 请求体 | `dav.mbt::propfind`，构造 `Request` 记录后交宿主 | `src/xmlutil/propfind.mbt` 生成体 + `src/client/dir_ops.mbt` 用 moonhttp 实际发出 |
| Multi-Status 解析 | `multistatus.mbt::parse_responses`，自研解析器 | `src/xmlutil/multistatus.mbt` 基于 `Milky2018/xml` 的命名空间事件流，`src/xmlutil/resource.mbt` 装配 `FileInfo` |
| XML 基础层 | 自研 `xml.mbt`（648 行，拒绝 DTD 与外部实体） | 复用生态库 `Milky2018/xml`，仅自研 DAV 专层（`src/xmlutil/`） |
| LOCK 请求体 | `authoring.mbt::lock_request` | `src/xmlutil/lockinfo.mbt::lockinfo_body` + `src/client/lock_ops.mbt` |
| 路径百分号编码 | `dav.mbt::path` 手写逐字节编码 | `src/types/urlcodec.mbt` 的 `percent_encode_path` + `href_to_path` 归一 |
| `If` 头 | `authoring.mbt::if_tokens` / `if_resources`，自述「只产生一个正向 AND 列表，不提供完整 Not/ETag/OR 条件表达式」 | `src/client/if_header.mbt` 完整渲染（列表内合取、列表间析取、`Not`、`[etag]`、带标签列表）并在发包前做四类本地 400 校验 |
| HTTP 执行 | **不在包内**，由 Node 宿主 `tools/client.mjs` 承担 | `src/client/client.mbt` 在 MoonBit 内基于 moonhttp 执行，`Transport` 接口可整体替换 |

关键区别一句话：**对照包的 MoonBit 侧只产出请求记录与解析响应，不发起网络请求；
本仓的 MoonBit 侧就是客户端本身。**

## 2 native 集成的新增核心职责

「native 集成」在本仓不是一层薄封装，而是新增了下列职责。对照列中「包内无」指
对照包 `pkg.generated.mbti` 的 16 个顶层非 async 纯函数（`propfind` / `proppatch` /
`copy_move` / `lock_request` / `refresh_lock` / `unlock_request` / `if_tokens` /
`if_resources` / `path` / `property_xml` / `set_properties` / `parse_xml` /
`parse_responses` / `parse_multistatus` / `parse_locks`）均无对应导出（其等价能力若存在，
位于 Node 宿主而非 MoonBit 包）。

| # | 新增职责 | 本仓入口 / 实现 | 对照包 | 验证 |
|---|----------|----------------|--------|------|
| 1 | MoonBit 内真实网络执行（async 运行时 + 可插拔 `Transport`） | `create_webdav_client` / `create_webdav_client_with_transport`、`src/client/client.mbt` | 包内无（在 Node） | `client_test.mbt`（MockTransport 注入）+ 真实服务器全流程 |
| 2 | 流式上传三形态：内存 `Bytes` / 任意 `&@io.Reader` / 本地文件路径，定长或 chunked、64 KiB 进度回调 | `src/client/file_ops.mbt` | 包内无 | `file_ops_test.mbt`；演示 100 KiB 往返逐字节比对 |
| 3 | 下载三形态：全量到内存 / 分块回调 / 流式写盘 | `src/client/download_ops.mbt` | 包内无 | `download_ops_test.mbt` |
| 4 | 区间下载（`Range`，206 / 200 双状态、`Content-Range` 解析） | 三个下载方法共用的 `range? : ByteRange` | 包内无 | `download_range_test.mbt` |
| 5 | 断点续传状态机（206 追加 / 200 回退重写 / 416 视为已完成 / `If-Range` 防篡改） | `src/client/download_resume.mbt` | 对方 `FEATURES.md` 自述「不提供断点续传」 | `download_range_test.mbt` + 演示「续传拼接后内容一致」 |
| 6 | 递归建目录（逐级 MKCOL，405 跳过、409 先 PROPFIND 复核） | `src/client/mkdir_all.mbt` | 包内无 | `mkdir_all_test.mbt` + 演示幂等重跑 |
| 7 | 完整 `If` 渲染与发包前本地校验 | `src/client/if_header.mbt` | 仅正向 AND 列表 | `if_header_test.mbt`（含四类 400 且断言零请求） |
| 8 | 423 自动补令牌重试 + 进程内锁注册表（同路径 / infinity 祖先） | `src/client/lock_registry.mbt`、`client.mbt` | 包内无 | `lock_retry_test.mbt`、`lock_registry_wbtest.mbt` |
| 9 | lock-null 空资源清理（UNLOCK → HEAD 确认零长 → `If-Match` DELETE） | `src/client/lock_cleanup.mbt` | 包内无 | `lock_cleanup_test.mbt` + 演示 |
| 10 | 取消语义：全部网络方法透传 `AbortSignal`，取消与网络故障分流为 `Cancelled` | `client.mbt`、`src/types/result.mbt` | 包内无 | `webdav_test.mbt` |
| 11 | 错误六分类：网络 / XML / 非期望状态码 / 207 部分失败 / 已取消 / 本地文件；`Api` 消息附响应体诊断 | `src/client/status.mbt`、`src/types/types.mbt` | 仅 `DavError::Invalid` 一种 | `transfer_ops_test.mbt`（207 → `Partial`） |
| 12 | 能力探测与 HEAD 回退（`DAV` / `Allow` / `Server`；HEAD 405/501 → PROPFIND） | `src/client/probe_ops.mbt` | 包内无 | `probe_ops_test.mbt` + 演示（`/demo` 前缀触发回退） |
| 13 | 本地文件形态保障：先请求后建文件、句柄必关、长度快照、失败残留可续传 | `file_ops.mbt` / `download_ops.mbt` / `download_resume.mbt` | 包内无 | `file_ops_test.mbt`、`download_ops_test.mbt`（404 不创建本地文件） |

另有 `src/types/urlcodec.mbt`（percent 编解码、`href_to_path` 归一、ASCII 大写）
与 `src/types/protocol.mbt`（`Depth` / `Conditions` / `IfList` / `IfCondition` /
`ServerCapabilities`）等类型层，同样为包内新增。

## 3 边界声明（避免过度声明，也说明对方所长）

申诉不等于否认差异，本仓明确以下事实：

- **本仓不具备**：Digest 认证（对方在 Node 宿主实现，含 MD5 / SHA-256 / SHA-512-256、
  `sess`、UTF-8 凭据）、TLS 信任链三种场景的专项用例、XML 参考向量对照（对方 150 条）。
  本仓认证目前只有 Basic；Digest 列在 `docs/03-gap-analysis.md` 的 P1 候选。
- **本仓不做**：CalDAV / CardDAV、RFC 3253 版本控制、RFC 3744 ACL、RFC 5323 SEARCH、
  RFC 6578 Sync Collection、POST；多区间 `Range`；`>2GB` 资源的区间端点（受 `Int32` 约束）。
- **本仓仅在 native 后端可用**（依赖 `moonbitlang/async` 运行时），对照包在 JS / Wasm-GC
  下可构建——这是两者技术路线的根本差异，而非能力差距。
- 本仓**不声称生态空白**：对照包与 `justinwongcn/moon-ical`（含最小 CalDAV 服务端）
  均为 MoonBit 生态中既有的 DAV 实现；本仓的定位是「在 MoonBit 内完成网络执行的
  完整客户端」，与「协议语义层 + Node 宿主」互补而非重复。

## 4 复核方式

```bash
git log --oneline                      # 15 次提交，无共同祖先
grep -rn "liu-fang38" src moon.mod     # 零命中（源码与依赖清单）
python3 tools/similarity_check.py      # 重合度四指标（本文第 1.3 节）
bash src/main/run_tests.sh             # 164 用例 + 真实服务器全流程
```

文档索引见 `docs/README.md`；RFC 4918 逐章节范围与案例见 `docs/08-rfc4918-scope.md`。
