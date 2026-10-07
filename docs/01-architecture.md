# 架构与协议映射

## 模块概览

- 模块：`q2316367743/webdav`（moon.mod，`source = "src"`，`preferred_target = "native"`——moonhttp 基于 moonbitlang/async，仅 native 可用）
- 依赖：`q2316367743/moonhttp@0.5.0`（HTTP 客户端，流式请求体 / 流式响应 / 取消信号）、`Milky2018/xml@0.5.0`（XML 解析）、`moonbitlang/async@0.22.2`（测试与演示程序；`src/client` 另引其 `io` 子包）
- 根包直接 import moonhttp，是为了从门面再导出 `AbortController` / `AbortSignal`（取消能力要让调用方拿到具体类型）

## 包结构与依赖方向

```
src/webdav.mbt + src/moon.pkg   根包（门面）：using 重导出 + 薄包装函数
        │
        ├──> src/client/   WebdavClient 与全部操作
        │        client（send / url_for / 配置）· status（状态码判定 / 207 失败提取）
        │        probe_ops（OPTIONS / exists）· file_ops · dir_ops · transfer_ops
        │        ├──> src/types/    公共类型（配置 / FileInfo / Progress / 错误 /
        │        │                  protocol：Depth·Conditions·ServerCapabilities·
        │        │                  PropResult·ResourceFailure / result：Put·Get）
        │        │                  + percent 编解码与 href 归一
        │        └──> src/xmlutil/  PROPFIND / PROPPATCH 请求体生成、
        │                  multistatus（207 解析）· resource（FileInfo 装配）
        │                 └──> src/types/
        └──> src/types/

src/main/   演示程序（executable，.moonignore 已排除，不随包发布）
```

依赖严格单向，无环。根包只有重导出（RL-02：根目录 / 门面不放业务逻辑）。

## 操作 ↔ HTTP 协议映射

所有请求经 moonhttp `Client::request`（XML / 流式 PUT / 无 body 操作）或 `Client::stream`（流式下载）；
实例默认配置带 `with_validate_status(fn(_) { true })`——**状态码一律由本层判定**，
`WebdavError::Api` 携带中文人读消息 + 响应体摘要（见 `status_message` / `body_hint`）。

| 操作 | 方法 | 关键头 | 请求体 | 期望状态码 |
|------|------|--------|--------|-----------|
| `put_file` | PUT | Content-Type（可选）、If-Match / If-None-Match | 流式请求体（BytesReader 拉取，定长 Content-Length） | 200/201/204 |
| `get_file` | GET | If-Match / If-None-Match | - | 200 |
| `download_file` | GET | 同上 | - | 200（流式） |
| `mkdir` | MKCOL | - | - | 201 |
| `delete` | DELETE | - | - | 200/204/207（207 有失败条目 → `Partial`） |
| `exists` | HEAD | - | - | 200/204/304→true，404→false，405/501→回退 PROPFIND |
| `options` | OPTIONS | - | - | 200/204（读 `DAV` / `Allow` / `Server`） |
| `list` | PROPFIND | Depth:0/1/infinity, Content-Type: xml | allprop XML | 207 |
| `stat` | PROPFIND | Depth:0 | allprop XML | 207 |
| `get_properties(_with_status)` | PROPFIND | Depth:0 | named-prop XML | 207 |
| `set_properties` | PROPPATCH | Content-Type: xml | propertyupdate XML | 207 |
| `move_path` | MOVE | Destination(绝对URL), Overwrite T/F, Depth | - | 201/204/207（同上） |
| `copy_path` | COPY | 同上 | - | 201/204/207（同上） |

条件头由 `Conditions` 统一生成（`apply_conditions`）；取消信号经 `Client::request(cfg, signal?)`
透传（`send` 的可选 `signal?` 参数）。Basic Auth 由 moonhttp `with_auth` 自动携带
（`Authorization: Basic ...`）。

## 关键实现决策

### 1. URL 与路径

- `base_url` 规范化：去尾斜杠（`normalize_base`）。
- 用户 `path` 先 percent 编码（`@types.percent_encode_path`：保留 `/` 与 unreserved，
  其余逐 UTF-8 字节 `%XX`，空格为 `%20`）再拼到 base 后，即请求 URL。
- MOVE/COPY 的 `Destination` 必须是绝对 URL，直接用同一拼法。
- 服务端返回的 href 与用户 path 不同纲：用 `@types.href_to_path` 归一再比
  （剥 `scheme://authority`、丢 `?query` / `#fragment`、percent 解码、去尾斜杠），
  因此绝对 URL 形式的 href 也能正确排除自身、算出显示名。

### 2. 状态码接管与部分失败

moonhttp 默认非 2xx 抛 `HttpError`，但 WebDAV 中 404（exists）/ 207（PROPFIND 与
带部分失败的 DELETE/MOVE/COPY）需要本层分支处理，故统一放行后由 `check_status`
按 ok 集合转 `WebdavError::Api(status~, operation~, message~)`；失败消息附响应体前
200 字符（`body_hint`），便于定位服务端解释。

207 是「可能部分失败」的信号：`check_status_allow_partial` 解析 multi-status，
`failures_from_multistatus` 收集 response 级 status 非 2xx 的条目，非空则抛
`WebdavError::Partial(operation, failures)`——**不再把部分失败当成功**。

### 3. 流式上传（moonhttp 0.5 流式请求体 + BytesReader）

moonhttp 0.5 支持流式请求体（`Config::with_data_from_stream(reader, content_length?)`，
见 moonhttp docs/20），`put_file` 把入参 `Bytes` 包成 `priv struct BytesReader`
（实现 `@io.Reader` 的拉取式适配器：`_direct_read` 按块把视图切片搬给泵循环，
不引入协程与管道、不拷贝整份数据）后走 `with_data_from_stream`，并声明
`content_length=data.length()`——定长 `Content-Length` 分帧，上传进度每
64 KiB 分块回调、`total` 已知，经 `Config::with_on_upload_progress` 接线
（`adapt_progress` 适配，与下载侧同一套 `Progress`）。

包外实现 `@io.Reader` 依赖 async 的 `ReaderBuffer` 公开构造与 trait 的两个
必需方法——moonhttp 的 stream_wire_test 已把这一前提钉死；`src/client/moon.pkg`
因此按包抑制 `alert_internal`。曾用的 `BinaryBodyTransport` 传输层装饰器
（moonhttp 0.4 时代的全量注入方案）已随本次升级整体移除。

### 4. 流式下载

`Client::stream` 拿到 `StreamResponse` 后循环 `read_some(max_len=chunk_size)`：
每块交 `on_chunk`，`loaded` 累计回调 `on_progress`，`total` 取响应头 `Content-Length`
（缺失为 `None`）。结束 / 异常都保证 `close()`（try/catch 包裹 + Result 汇聚）；
读流异常经 `map_http_error` 归一（取消 → `Cancelled`，其余 → `Http`）。

### 5. XML 解析（src/xmlutil）

`NamespaceReader` 事件流 + local_name 栈：按 `local_name` + `namespace_uri == Some("DAV:")`
匹配（不依赖前缀写法，默认命名空间响应同样正确）。要点：

- `resourcetype` 内出现 `collection`（Start 或 Empty）→ 目录；
- prop 下的叶子元素累积 Text/CData 为属性值（实体由库解码）；
- **propstat 的状态码逐段归属**：属性先进 `pending_props`，遇到 `</D:propstat>`
  时按该段的 `<D:status>` 打标（状态行常排在 `<D:prop>` 之后），404 与「空值」因此
  可区分；response 级 `<D:status>` / `<D:responsedescription>` 单独记在
  `ParsedResource.status` / `.responsedescription`（207 部分失败靠它）；
- `find_prop` 只认 2xx 属性；
- 空自闭合叶子（如 `<D:getetag/>`）记空串属性；
- 文件行数上限（RL-04）把 FileInfo 装配拆到 `src/xmlutil/resource.mbt`
  （`display_name` / `find_prop` / `to_file_info` / `parse_prop_int`）。

### 6. 能力探测与 HEAD 回退（src/client/probe_ops.mbt）

`options(path?, signal?)` 解析 `DAV`（缺省 `[1]`）/ `Allow`（ASCII 大写）/ `Server`，
`ServerCapabilities::supports`（大小写不敏感）与 `has_lock` 供调用方按能力选择路径。

`exists` 先用 HEAD（200/204/304 → true，404 → false）；服务端 405/501 时改写
PROPFIND `Depth:0` allprop 再判定（404 → false，其余重抛）。这样兼容禁用 HEAD 的服务器。

### 7. 条件请求与取消

`Conditions` 只承载 `If-Match` / `If-None-Match`，由 `apply_conditions` 写进请求配置，
所有写 / 读操作都接受 `conditions?`。取消走 moonhttp 的 `AbortSignal`：
`send` 把 `signal?` 转发给 `Client::request`，`map_http_error` 用
`HttpError::is_cancelled()` 把取消与网络错误分开，取消时取 `AbortSignal::reason()`
填进 `Cancelled(reason?)`。

## 测试策略

- 白盒：`src/types/urlcodec_wbtest.mbt`（编解码、`href_to_path` 归一形态）、
  `src/xmlutil/xmlutil_wbtest.mbt`（请求体形状、前缀差异 / 中文 href / 自定义属性解析、
  propstat 200/404/403 逐段归属、response 级 status）。
- 黑盒：`src/client/*_test.mbt` 用 `MockTransport`（moonhttp/transport 公开）
  断言每个操作的请求形状（方法 / URL / 头 / body）与错误分支；`probe_ops_test`
  覆盖 OPTIONS 解析与 HEAD 回退，`transfer_ops_test` 覆盖 207 部分失败（`Partial`）、
  `dir_ops_test` 覆盖 Depth 与绝对 href 归一、`file_ops_test` 覆盖新返回类型与条件头；
  `src/webdav_test.mbt` 从 `@webdav` 门面走完整操作流（`from_responses` 按序供响应，
  含 OPTIONS 与门面重导出 / 取消信号用例）。
- 当前规模：`moon test --target native` 55 个用例全绿。
- 一键测试：`bash src/main/run_tests.sh`——自动起 WebDAV 服务端（优先
  brew 的 `webdav`，回退 `src/main/testdata/verify_server.py`）、跑
  `moon test` 全套测试、连真实服务端跑 `moon run src/main` 全流程
  （含 testdata 真实文件往返：`binary.bin` 100 KiB 走 64 KiB 分块进度、
  中文文件名端到端编码），最后关闭服务端并汇总 PASS/FAIL。
  `src/main/testdata/` 即真实测试文件（样本文件 + 兜底服务端脚本）。

  兜底服务器 `verify_server.py` 刻意对齐协议细节：`Depth:1` 不递归、
  `Depth:infinity` 才整树、支持 `propname`、没存过的死属性回 404 propstat；
  `run_tests.sh` 以 `VERIFY_NO_HEAD_PREFIX=/demo` 启动它，让 `/demo` 下的 HEAD
  返回 405，从而在真实链路上覆盖 `exists` 的 PROPFIND 回退分支。

  手工起服务端（brew `webdav`，hacdias）时的注意：v5 的权限字母是
  C/R/U/D（Create/Read/Update/Delete），不是旧版的 R/W/D，写 RWD 会启动失败：

  ```yaml
  address: 127.0.0.1
  port: 8082
  directory: /tmp/webdav-brew-test
  users:
    - username: demo
      password: demo
      permissions: CRUD
  ```

  已知差异：hacdias/webdav 的 PROPPATCH 返回 207 但**不持久化死属性**
  （PROPFIND 按名读回时 propstat 带 404），`get_properties` 表现为属性不存在；
  `rclone serve webdav` 同样基于 x/net/webdav，死属性行为一致。回退的
  Python 服务器则把死属性存在内存里，能读回（`run_tests.sh` 两条路径
  的差异会体现在 demo 的 `PROPPATCH color=` 一行）。

## 注意事项

- `put_file` 的 `data` 契约仍是「完整内容已在内存」（签名 `data~ : Bytes`），
  上传过程不再额外整份拷贝；真正的「从磁盘边读边发」留待后续 `put_file_stream`；
- `mkdir` 是单级（409 = 父不存在），递归创建留待后续；
- 尚无 LOCK/UNLOCK 与 `If:` 锁令牌（`has_lock()` 只做能力探测）；
- 扩展方法（REPORT / ACL 等）在 moonhttp 侧可直接经 `Method::Other(name)` 发送，
  架构上不需要改动，属于「加接口」；
- 根包 `DEFAULT_TIMEOUT_MS` / `DEFAULT_PROP_NS` 是从子包常量再导出的同值 const；
- 缺口清单与 P1 / P2 路线图见 `docs/03-gap-analysis.md`（标注「未联网核实」）。
