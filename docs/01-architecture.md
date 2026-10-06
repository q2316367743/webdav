# 架构与协议映射

## 模块概览

- 模块：`q2316367743/webdav`（moon.mod，`source = "src"`，`preferred_target = "native"`——moonhttp 基于 moonbitlang/async，仅 native 可用）
- 依赖：`q2316367743/moonhttp@0.5.0`（HTTP 客户端，流式请求体）、`Milky2018/xml@0.5.0`（XML 解析）、`moonbitlang/async@0.22.2`（测试与演示程序；`src/client` 另引其 `io` 子包）

## 包结构与依赖方向

```
src/webdav.mbt + src/moon.pkg   根包（门面）：using 重导出 + 薄包装函数
        │
        ├──> src/client/   WebdavClient 与全部操作（client / file_ops / dir_ops / transfer_ops 四文件）
        │        ├──> src/types/    公共类型（配置 / FileInfo / Progress / 错误）+ percent 编解码
        │        └──> src/xmlutil/  PROPFIND / PROPPATCH 请求体生成、207 Multi-Status 解析
        │                 └──> src/types/
        └──> src/types/

src/main/   演示程序（executable，.moonignore 已排除，不随包发布）
```

依赖严格单向，无环。根包只有重导出（RL-02：根目录 / 门面不放业务逻辑）。

## 操作 ↔ HTTP 协议映射

所有请求经 moonhttp `Client::request`（XML / 流式 PUT / 无 body 操作）或 `Client::stream`（流式下载）；
实例默认配置带 `with_validate_status(fn(_) { true })`——**状态码一律由本层判定**，
`WebdavError::Api` 携带中文人读消息（见 `status_message`）。

| 操作 | 方法 | 关键头 | 请求体 | 期望状态码 |
|------|------|--------|--------|-----------|
| `put_file` | PUT | Content-Type（可选） | 流式请求体（BytesReader 拉取，定长 Content-Length） | 200/201/204 |
| `get_file` | GET | - | - | 200 |
| `download_file` | GET | - | - | 200（流式） |
| `mkdir` | MKCOL | - | - | 201 |
| `delete` | DELETE | - | - | 200/204 |
| `exists` | HEAD | - | - | 200/204→true，404→false |
| `list` | PROPFIND | Depth:1, Content-Type: xml | allprop XML | 207 |
| `stat` | PROPFIND | Depth:0 | allprop XML | 207 |
| `get_properties` | PROPFIND | Depth:0 | named-prop XML | 207 |
| `set_properties` | PROPPATCH | Content-Type: xml | propertyupdate XML | 207 |
| `move_path` | MOVE | Destination(绝对URL), Overwrite T/F | - | 201/204 |
| `copy_path` | COPY | 同上 | - | 201/204 |

Basic Auth 由 moonhttp `with_auth` 自动携带（`Authorization: Basic ...`）。

## 关键实现决策

### 1. URL 与路径

- `base_url` 规范化：去尾斜杠（`normalize_base`）。
- 用户 `path` 先 percent 编码（`@types.percent_encode_path`：保留 `/` 与 unreserved，
  其余逐 UTF-8 字节 `%XX`，空格为 `%20`）再拼到 base 后，即请求 URL。
- MOVE/COPY 的 `Destination` 必须是绝对 URL，直接用同一拼法。

### 2. 状态码接管

moonhttp 默认非 2xx 抛 `HttpError`，但 WebDAV 中 404（exists）/ 207（PROPFIND）等需要
本层分支处理，故统一放行后由 `check_status` 按 ok 集合转 `WebdavError::Api(status~, operation~, message~)`。

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
（缺失为 `None`）。结束 / 异常都保证 `close()`（try/catch 包裹 + Result 汇聚）。

### 5. list 的自身排除（href 对齐）

服务器返回的 href 是**服务器视角的完整路径**（含挂载前缀），与用户 path 不同纲。
对齐三步：`base_path_prefix(base_url)`（`http://h:8080/dav` → `/dav`）+ 用户 path
拼出服务器路径 → `percent_decode(href)` → 双方去尾斜杠比较（`same_resource`）。
不依赖服务端的编码风格（解码后比较）。

### 6. XML 解析（src/xmlutil/multistatus.mbt）

`NamespaceReader` 事件流 + local_name 栈：按 `local_name` + `namespace_uri == Some("DAV:")`
匹配（不依赖前缀写法，默认命名空间响应同样正确）。要点：

- `resourcetype` 内出现 `collection`（Start 或 Empty）→ 目录；
- prop 下的叶子元素累积 Text/CData 为属性值（实体由库解码）；
- `propstat` 的 status 行宽松忽略（404 的属性表现为空值）；
- 空自闭合叶子（如 `<D:getetag/>`）记空串属性。

## 测试策略

- 白盒：`src/types/urlcodec_wbtest.mbt`（编解码）、`src/xmlutil/xmlutil_wbtest.mbt`
  （请求体形状、前缀差异 / 中文 href / 自定义属性解析）。
- 黑盒：`src/client/*_test.mbt` 用 `MockTransport`（moonhttp/transport 公开）
  断言每个操作的请求形状（方法 / URL / 头 / body）与错误分支；
  `src/webdav_test.mbt` 从 `@webdav` 门面走完整操作流（`from_responses` 按序供响应）。
- 一键测试：`bash src/main/run_tests.sh`——自动起 WebDAV 服务端（优先
  brew 的 `webdav`，回退 `src/main/testdata/verify_server.py`）、跑
  `moon test` 全套测试、连真实服务端跑 `moon run src/main` 全流程
  （含 testdata 真实文件往返：`binary.bin` 100 KiB 走 64 KiB 分块进度、
  中文文件名端到端编码），最后关闭服务端并汇总 PASS/FAIL。
  `src/main/testdata/` 即真实测试文件（样本文件 + 兜底服务端脚本）。

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
  上传过程不再额外整份拷贝；真正的「从磁盘边读边发」留待后续 `put_file_stream`（如需要）；
- `mkdir` 是单级（409 = 父不存在），递归创建留待后续；
- moonhttp 的进度回调里做 HTTPS 取消有已知崩溃问题（moonhttp docs/13），
  本客户端未暴露取消能力，不受影响；
- 根包 `DEFAULT_TIMEOUT_MS` / `DEFAULT_PROP_NS` 是从子包常量再导出的同值 const。
