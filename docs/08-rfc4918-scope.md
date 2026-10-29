# RFC 4918 兼容范围与案例

本文档答复赛事初审第三问：**RFC 4918 的最终兼容范围**，并附可复现案例。
复用边界与 native 新增职责见 `docs/07-reuse-boundary.md`。

- 本仓基准：提交 `43b2eca`（版本 0.1.0），观测日 2026-10-16
- 判据：以「本仓公开 API 是否实现该章节要求的行为」为准，不以服务端是否配合为准；
  服务端不支持的能力按预期软跳过并如实记录（第 5 节）

## 1 已实现（逐章节）

| RFC 4918 章节 | 能力 | 本仓入口 | 案例位置 |
|---------------|------|----------|----------|
| §4.4 属性名与命名空间 | 按 local name + 命名空间匹配，不依赖前缀写法；自定义属性用自有命名空间 `urn:q2316367743:webdav:prop` | `src/xmlutil/multistatus.mbt`、`propfind_named_body` | `xmlutil_wbtest.mbt`（前缀差异 / 自定义属性） |
| §5.2 集合资源 | 目录识别（`resourcetype` 内 `collection`） | `ParsedProp` → `FileInfo.is_dir` | `dir_ops_test.mbt` |
| §6.7 锁能力发现 | 解析 `DAV`（缺省 `[1]`）/ `Allow` / `Server` | `options` → `ServerCapabilities::has_lock` | `probe_ops_test.mbt` + 演示「DAV 等级 2 个，LOCK=true」 |
| §6.8 活动锁发现 | 解析 `lockdiscovery` 为结构化 `ActiveLock` | `get_locks`、`src/xmlutil/lockinfo.mbt` | `lockinfo_wbtest.mbt`、`lock_ops_test.mbt` |
| §7.3 未映射 URL 上的写锁（lock-null） | 201 = 创建 lock-null；收尾时 UNLOCK → HEAD 确认零长 → `If-Match` DELETE | `lock` 的 `LockResult.created`、`cleanup_lock_null` | `lock_cleanup_test.mbt` + 演示「lock-null 清理」 |
| §7.5 写锁与 `If` 头 | 锁令牌写入 `If: (<令牌>)`，写操作自动携带 | `Conditions::new(lock_token=…)` | `lock_ops_test.mbt` |
| §7.7 刷新写锁 | 无请求体 LOCK + `If`，令牌不变 | `refresh_lock` | `lock_ops_test.mbt` + 演示「刷新锁（Timeout → Second-600）」 |
| §8.2 XML 使用 | 命名空间感知的生成与解析；实体解码交由生态库 | `src/xmlutil/` 全部 | `xmlutil_wbtest.mbt` |
| §8.3 URL 处理 | percent 编解码、`href` 归一（剥 scheme/authority、丢 query/fragment、去尾斜杠） | `src/types/urlcodec.mbt` | `urlcodec_wbtest.mbt`、`dir_ops_test.mbt`（绝对 href） |
| §8.6 ETag | `If-Match` / `If-None-Match`；`If-Range` 用于续传防篡改 | `Conditions`、`download_to_path_resume(etag?)` | `client_test.mbt`、`download_range_test.mbt` |
| §9.1 PROPFIND | `Depth: 0/1/infinity`；`allprop` 与按名请求；`propstat` 逐段状态归属（404 与空值可区分） | `list` / `list_recursive` / `stat` / `get_properties(_with_status)` | `dir_ops_test.mbt`、`xmlutil_wbtest.mbt` |
| §9.2 PROPPATCH | `<D:set>` 设置自定义属性（原子 set，不含 remove） | `set_properties` | `client_test.mbt` + 演示「PROPPATCH color=」 |
| §9.3 MKCOL | 单级 `mkdir`；递归 `mkdir_all`（405 跳过 / 409 复核） | `mkdir` / `mkdir_all` | `mkdir_all_test.mbt` + 演示「MKCOL-ALL 幂等」 |
| §9.6 DELETE | 含 207 部分失败识别 | `delete` | `transfer_ops_test.mbt`（207 → `Partial`） |
| §9.7 PUT | 三形态上传、定长或 chunked、条件头、`PutResult`（ETag / Last-Modified / Location） | `put_file` / `put_file_stream` / `put_file_from_path` | `file_ops_test.mbt` + 演示 100 KiB 往返 |
| §9.8 COPY | `Destination` 绝对 URL、`Overwrite` T/F、`Depth`、207 部分失败 | `copy_path` | `dir_ops_test.mbt` + 演示「COPY → copy.txt」 |
| §9.9 MOVE | 同上 | `move_path` | `dir_ops_test.mbt` + 演示「MOVE → renamed.txt」 |
| §9.10 LOCK | 独占与共享（§9.10.5 兼容表语义由服务端裁决，客户端不越权）；§9.10.3 的 `Depth: 1` 本地拦 400；§9.10.4 未映射 URL 走 lock-null；令牌来源优先响应头、其次响应体 | `lock` / `get_locks` | `lock_ops_test.mbt`、`lock_scope_test.mbt` + 演示 423 → 带令牌 PUT |
| §9.11 UNLOCK | `Lock-Token` 头，令牌统一归一（`tok` / `<tok>` 等价） | `unlock` | `lock_ops_test.mbt` + 演示 |
| §10.1 DAV 头 | 解析服务器声明的等级与允许方法 | `options` | `probe_ops_test.mbt` |
| §10.2 Depth 头 | `Depth::Zero/One/Infinity` → `0` / `1` / `infinity` | `Depth::to_header` | `dir_ops_test.mbt` |
| §10.3 Destination 头 | 绝对 URL（同路径编码规则） | `copy_path` / `move_path` | `dir_ops_test.mbt` |
| §10.4 If 头 | 列表内合取、列表间析取、`Not`、`[etag]`、带标签列表；混用带标签与无标签、空列表、空标签、空令牌在发包前拦 400 | `src/client/if_header.mbt` | `if_header_test.mbt`（含断言零请求） |
| §10.5 Lock-Token 头 | 发送与解析（含响应头缺尖括号的容错） | `unlock`、`normalize_lock_token` | `lock_ops_test.mbt`、`types/lock_wbtest.mbt` |
| §10.6 Overwrite 头 | `T` / `F` | `copy_path(overwrite?)` / `move_path(overwrite?)` | `dir_ops_test.mbt` |
| §10.7 Timeout 头 | 请求侧发送与响应侧解析（`Second-600` 等） | `lock(timeout?)` / `refresh_lock(timeout?)` | `lock_ops_test.mbt`、`lockinfo_wbtest.mbt` |
| §11.1 207 Multi-Status | 解析 `response` / `href` / `propstat` / `status` / `responsedescription`；响应级非 2xx 条目汇总为 `WebdavError::Partial`，不再当成功 | `src/xmlutil/multistatus.mbt`、`status.mbt` | `transfer_ops_test.mbt`、`xmlutil_wbtest.mbt` |
| §15 DAV 属性 | `getcontentlength` / `getlastmodified` / `getetag` / `resourcetype` / `getcontenttype` / `creationdate` 等装配进 `FileInfo`；`lockdiscovery` 结构化解析 | `src/xmlutil/resource.mbt` | `xmlutil_wbtest.mbt` |

此外实现 RFC 7233（`Range` / `Content-Range` / `If-Range` / 206 / 416）用于区间下载与
断点续传，见 `docs/06-range-resume.md`；该部分不属于 RFC 4918，单列说明以免混淆范围。

## 2 部分实现或未暴露

| 项 | 现状 |
|----|------|
| §9.4 集合的 GET / HEAD | 不适用：本仓不对集合做 GET（WebDAV 未要求集合有实体表示）；`exists` 对任意资源先用 HEAD，服务端 405/501 时回退 PROPFIND `Depth:0` |
| §9.1.4 `propname` | 请求体生成器 `propfind_propname_body()` 已实现并被白盒用例覆盖，但客户端未暴露对应公开方法（按名或 `allprop` 已覆盖实际需求） |
| §9.1.6 `allprop` + `include` | 未实现；`allprop` 与按名请求互斥使用 |
| §9.2 `<D:remove>` | 未实现，PROPPATCH 目前只做 `set`；列在 `docs/03-gap-analysis.md` 的 P1 候选 |
| `PropResult` 命名空间 | `get_properties_with_status` 返回的 `name` 不含命名空间，同名属性可能撞车；P1 候选 |
| `DAV:error` 条件错误体 | 未解析；失败以状态码 + 响应体摘要呈现（`status_message` + `body_hint`） |

## 3 明确不做

CalDAV（RFC 4791）/ CardDAV（RFC 6352）、RFC 3253 版本控制、RFC 3744 ACL、
RFC 5323 SEARCH、RFC 6578 Sync Collection、§9.5 POST、Digest 认证（P1 候选）、
多区间 `Range`（`bytes=0-1,5-9`）与 multipart/byteranges、`>2GB` 资源的区间端点
（受 `Int32` 约束）。扩展方法（REPORT 等）无需改架构，经 moonhttp 的
`Method::Other(name)` 即可发送，属「加接口」。

## 4 状态码处理策略

- **顶层状态码**：不在期望集合内即抛 `WebdavError::Api(status, operation, message)`；
  消息为中文注解 + 响应体前 200 字符摘要。已注解：200/201/204/206/207/301/302/307/308/
  400/401/403/404/405/409/412/416/423/502/504/507；其余（含 422 `Unprocessable Entity`、
  424 `Failed Dependency`）走通用文案，但**状态码本身原样保留**在 `Api.status`。
- **207 内部逐段状态码**：`propstat` 的状态按段归属到每个属性（`ParsedProp.status`），
  `response` 级状态码归属到 `ParsedResource.status`；`find_prop` 只认 2xx，
  故「属性不存在（404）」与「属性值为空」可区分。
- **部分失败**：DELETE / MOVE / COPY / PROPPATCH 收到 207 且存在非 2xx 条目时抛
  `Partial(operation, failures)`，不视为成功。
- **不自动重试**：仅 `WebdavConfig::retry_on_423`（默认关）在 423 时补令牌重试一次；
  5xx 与断线不做退避重试（P2 候选）。

## 5 当次可复现案例

### 5.1 命令

```bash
bash src/main/run_tests.sh    # 自动起服务端 → moon test → 真实全流程 → 关闭并汇总
```

2026-10-16 当次运行，服务端为 hacdias/webdav v5（本地 `webdav` 命令），
结果：**阶段 1「Total tests: 164, passed: 164, failed: 0」PASS；
阶段 2 真实全流程 PASS**。逐项输出摘录：

```
✓ MKCOL /demo
✓ MKCOL-ALL /demo/相册/2024/深/层      ← 多级中文路径递归创建
✓ MKCOL-ALL 幂等（已存在层级回 405 跳过）
✓ PUT /demo/hello.txt（HTTP 201，ETag "18dee5a9c026d1773d"）
✓ STAT 大小一致（61 字节）
✓ LIST /demo（2 项）  - [目录] 相册   - [文件] hello.txt
✓ GET（流式）内容一致
✓ GET（区间 206）内容一致
✓ 断点续传拼接后内容一致
✓ MOVE /demo/hello.txt → /demo/renamed.txt
✓ COPY /demo/renamed.txt → /demo/copy.txt
✓ 本地路径流式往返 binary.bin（102400 字节）一致
✓ 特殊文件名上传下载往返一致
✓ OPTIONS：DAV 等级 2 个，允许方法 8 个，LOCK=true
✓ EXISTS /demo/renamed.txt ；✓ EXISTS /demo/not-here.txt 为假
✓ LOCK /demo/locked.txt（令牌 1792122240）
  无令牌 PUT 被拒：HTTP 423 资源被锁定（响应体：Locked）
✓ 带锁令牌 PUT（HTTP 201）
✓ 刷新锁（Timeout → Second-600）
✓ UNLOCK /demo/locked.txt
✓ lock-null 清理（/lock-null-demo.txt）→ ✓ lock-null 资源已删除
✓ 423 自动补令牌重试（HTTP 201）
```

服务端能力不足的部分按预期软跳过（不计失败，如实记录）：

```
（服务端 PROPFIND 不回 lockdiscovery，跳过锁发现校验）
（服务端不支持该能力，跳过 带标签 If（Tagged-list）：HTTP 412 …）
（服务端不支持该能力，跳过 共享锁：HTTP 501 Not Implemented）
```

这说明兼容范围是被**实测**过的：hacdias/webdav 不支持共享锁与带标签 `If`，
这两条改由 `src/main/testdata/verify_lock.py` + `verify_if.py`（本仓自带的
Python 兜底服务端，含内存锁表与 `If` 解析子集）覆盖，命令同为 `run_tests.sh`。

### 5.2 单点复现（不依赖外部服务端）

```bash
moon test                       # 164 个用例：MockTransport 注入，断言请求形状与错误分支
moon test --target native -v    # 逐用例名
```

## 6 已知限制

- 服务端兼容证据来自：hacdias/webdav v5（真实全流程）+ 本仓 Python 兜底服务端
  （锁与 `If` 分支）。**未做** Apache mod_dav、IIS、Nextcloud/SabreDAV 的实测，
  故不声称「全部 WebDAV 服务端兼容」。
- 锁发现依赖服务端实现 `lockdiscovery`；hacdias 只回空元素（已在演示中体现）。
- PROPPATCH 死属性是否持久化由服务端决定：hacdias 与 `rclone serve webdav`
  不持久化（读回 404），Python 兜底服务端存内存可读回。
- 进度与区间端点受 `Int32` 约束，单次请求一个区间。
