# API 参考

对外 API 统一经根包门面（`@webdav`）访问；类型与方法随 `create_webdav_client`
返回的 `WebdavClient` 使用。全部网络方法是 `async ... raise WebdavError`，
且都接受可选参数：

- `signal? : @webdav.AbortSignal`：取消信号（`@webdav.AbortController` 从门面再导出，
  来自 moonhttp）；取消映射为 `WebdavError::Cancelled(reason?)`。
- `conditions? : @webdav.Conditions`：条件请求（`If-Match` / `If-None-Match`）。

## 创建客户端

```moonbit
let client = @webdav.create_webdav_client({
  base_url: "http://127.0.0.1:8080/dav/", // 末尾斜杠可有可无
  username: Some("user"),                  // Basic Auth，均 None 时不携带
  password: Some("pass"),
  timeout_ms: None,                        // None → DEFAULT_TIMEOUT_MS（30 秒）
})
```

另有两个入口：

- `create_webdav_client_with_transport(config, transport)`：注入自定义 / Mock 传输层；
- `DEFAULT_TIMEOUT_MS`、`DEFAULT_PROP_NS`：两个公开常量。

## 类型

### WebdavConfig

字段见上例，全部可直接构造，`derive(Default)`。

### FileInfo（PROPFIND 结果）

| 字段 | 类型 | 说明 |
|------|------|------|
| `href` | String | 服务端原始 href（URL 编码） |
| `name` | String | href 归一（剥 scheme/authority、去 query、percent 解码）后的显示名 |
| `is_dir` | Bool | 是否目录（collection） |
| `content_length` | Int? | 字节大小；目录 / 未知为 None |
| `content_type` | String? | MIME 类型 |
| `last_modified` | String? | RFC 1123 原样 |
| `created` | String? | RFC 3339 原样 |
| `etag` | String? | 含引号原样 |

### PutResult（`put_file` / `put_file_stream` / `put_file_from_path` 的返回值）

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | Int | 200 覆盖写 / 201 新建 / 204 |
| `created` | Bool | 是否新建（`status == 201`） |
| `etag` | String? | 响应 `ETag`（含引号原样） |
| `last_modified` | String? | 响应 `Last-Modified` |
| `location` | String? | 响应 `Location` |

### GetResult（`get_file` 的返回值，破坏性变更）

`content : Bytes`、`status : Int`、`content_type?`、`content_length? : Int?`、
`etag?`、`last_modified?`。

### Progress（进度快照）

`{ loaded : Int, total : Int? }`；`percent() -> Double?` 返回 `0.0 ~ 1.0`
（总长未知 / 为零时 `None`）。

### 协议小类型

| 类型 | 说明 |
|------|------|
| `Depth` | `Zero` / `One` / `Infinity`；`to_header()` 得 `"0"` / `"1"` / `"infinity"` |
| `Conditions` | `Conditions::new(if_match?, if_none_match?)`；省略即不发对应头，取值可含引号或 `*` |
| `ServerCapabilities` | OPTIONS 结果：`dav_class : Array[Int]`（无名头按 RFC 4918 §10.1 视为 `[1]`）、`allow : Array[String]`（ASCII 大写）、`server : String?`；`supports(http_method)` 大小写不敏感、`has_lock()` = DAV 含 2 或 Allow 含 LOCK |
| `PropResult` | `{ name, value, status }`：`status` 是该属性所在 propstat 的状态码，404 表示服务端没这个属性（与「值为空串」区分） |
| `ResourceFailure` | `{ href, status, message }`：207 里非 2xx 的那个资源 |

### WebdavError（统一错误，suberror）

```moonbit
match error.detail() {
  Http(http_error) => ...            // 网络 / HTTP 协议层（moonhttp）
  Xml(xml_error)   => ...            // 207 响应解析失败
  Api(status~, operation~, message~) => ... // 非期望状态码
  Partial(operation~, failures~)     => ... // 207 部分失败（failures : Array[ResourceFailure]）
  Cancelled(reason)                  => ... // 请求被取消（reason : String?）
  Io(message~)                       => ... // 本地文件系统错误（路径形态的传输）
}
```

- `Api` 的 `message` 是中文状态码注解，并附服务端响应体前 200 字符；
- `Io` 只由 `put_file_from_path` / `download_to_path` 产生（打开 / 读长度 /
  创建 / 写入本地文件失败），`message` 是中文描述 + 原始系统错误——
  本地问题不会被伪装成服务端问题；
- `error.to_string()` 得中文人读描述；实现了 `Show`，可直接 `println("\{error}")`；
- 便捷构造：`WebdavError::http / xml / api / partial / cancelled / io`（供扩展实现复用）。

## 方法一览（全部 `async raise WebdavError`）

除表中列出的专属参数外，所有方法都可选传 `signal?` / `conditions?`。

| 方法 | 签名要点 | 说明 |
|------|---------|------|
| `put_file` | `path~, data~ : Bytes, content_type?` → `PutResult` | PUT **全量字节**（内容须已在内存），流式发送 |
| `put_file_stream` | `path~, reader~ : &@io.Reader, content_length? : Int, content_type?` → `PutResult` | PUT **读取流**（边读边发）；给长度定长，不给走 chunked |
| `put_file_from_path` | `path~, local_path~ : String, content_type?` → `PutResult` | PUT **本地文件**（内部打开 / 取长度 / 边读边发 / 关闭，不读进内存） |
| `get_file` | `path~` → `GetResult` | GET 全量下载到内存 |
| `download_file` | `path~, on_chunk~ : (Bytes) -> Unit, chunk_size?` | 流式分块下载（默认 64 KiB；同步回调，适合内存消费） |
| `download_to_path` | `path~, local_path~ : String, chunk_size?` | 流式下载**写本地文件**（拿到 200 才建文件；async 写盘在内部完成） |
| `mkdir` | `path~` | MKCOL 单级建目录 |
| `delete` | `path~` | DELETE（207 部分失败 → `Partial`） |
| `exists` | `path~` → Bool | HEAD；405/501 自动回退 PROPFIND `Depth:0` |
| `list` | `path~, depth? : Depth` → `Array[FileInfo]` | 默认 `Depth::One`，不含自身 |
| `list_recursive` | `path~` → `Array[FileInfo]` | `Depth:infinity` 整树 |
| `stat` | `path~` → `FileInfo` | `Depth:0` |
| `options` | `path?` → `ServerCapabilities` | 能力探测（`DAV` / `Allow` / `Server`） |
| `move_path` | `src~, dst~, overwrite?（默认 true）, depth? : Depth` | MOVE（207 部分失败 → `Partial`） |
| `copy_path` | 同 `move_path` | COPY（同上） |
| `set_properties` | `path~, props~ : Array[(String, String)], ns_uri?` | PROPPATCH set |
| `get_properties` | `path~, names~, ns_uri?` → `Map[String, String]` | 按名 PROPFIND，只收 2xx 属性 |
| `get_properties_with_status` | 同上 → `Array[PropResult]` | 保留 404 属性的状态 |

## 语义细节

### 路径

- `path` 相对 `base_url`，建议以 `/` 开头（会自动补）；
- 中文、空格等自动 percent 编码（空格 → `%20`），无需调用方预处理；
- `move_path` / `copy_path` 的 `dst` 是路径（非完整 URL），客户端负责拼绝对 Destination；
- 服务端 href 与用户 path 不同纲：统一经 `@types.href_to_path` 归一
  （剥 scheme/authority、丢 `?query` / `#fragment`、percent 解码、去尾斜杠）后比较，
  因此绝对 URL 形式的 href 也能正确排除自身、算出显示名。

### 进度回调节奏

- 上传（`put_file` / `put_file_stream` / `put_file_from_path`）：moonhttp 传输层按
  64 KiB 分块写、逐块回调（真实网络进度）；声明了长度时 `total` 已知，chunked 时为 `None`；
- `get_file`：moonhttp 读响应体时分块回调；
- `download_file` / `download_to_path`：每收到一个 chunk 回调一次
  （`total` 来自 Content-Length，无长度时 `None`）；
- Mock 传输层不写连接，上传进度不触发（黑盒测试断言了这一点）。

### 三种上传形态（moonhttp 0.5 流式请求体）

三条入口只差「数据从哪来」，共用同一条 PUT 管线（`src/client/file_ops.mbt` 的私有
`send_put`）：`Config::with_data_from_stream(reader, content_length?)` 决定分帧，
`Content-Length` 由 moonhttp 分帧层管理，调用方无需（也不应）自行设置。

| 入口 | 数据源 | `content_length` | 内存行为 |
|------|--------|------------------|----------|
| `put_file` | 内存 `Bytes` | `data.length()` | 内容须已在内存；发送不额外整份拷贝（`BytesReader` 按块供给） |
| `put_file_stream` | 任意 `&@io.Reader` | 调用方传 `content_length?`；不传即 chunked | 与文件 / 数据源大小无关 |
| `put_file_from_path` | 本地文件路径 | 内部取 `File::size()` 快照 | **不读进内存**，传输层按 64 KiB 从文件拉取 |

`BytesReader` 是包内实现 `@io.Reader` 的拉取式适配器（`_direct_read` 把视图切片搬给
泵循环，不引入协程与管道），只服务 `put_file`；流式与路径形态把调用方的 reader 原样
转交传输层。

`put_file_stream` 的流是**一次性资源**：不要用同一条流发两次请求；遇到 307/308 这类
要求原样重放请求体的重定向时，moonhttp 直接报错而不是静默发空体；HTTP/1.0 目标必须
传 `content_length`（1.0 不认 chunked 请求体）。

### 本地文件形态（put_file_from_path / download_to_path）

两者都用 `moonbitlang/async/fs`（native 专属，与模块 `preferred_target = "native"` 一致）：

```moonbit
// 上传：打开 → 用文件长度声明 Content-Length → 边读边发 → 关闭
let put = client.put_file_from_path(
  path="/demo/big.bin",
  local_path="/Users/me/big.bin",
  content_type="application/octet-stream",
  on_progress=fn(p) { println("\{p.loaded}/\{p.total}") },
)
// 下载：先发请求拿 200，再建本地文件，边收边写
client.download_to_path(path="/demo/big.bin", local_path="/Users/me/big.copy")
```

语义与边界：

| 主题 | 口径 |
|------|------|
| 顺序 | `download_to_path` **先请求后建文件**：404 等失败不会清空本地已存在的同名文件 |
| 覆盖 | 本地文件已存在则截断覆盖（`CreateOrTruncate`） |
| 失败残留 | 取消或中途失败时本地可能留下部分内容，**不自动删除** |
| 句柄 | 两条路径都在成功与失败时关闭文件；`put_file_from_path` 打不开文件或路径是目录时抛 `Io` 且**不发任何请求** |
| 本地 IO 错误 | 统一为 `WebdavError::Io(message)`，不冒充 HTTP 错误 |
| 目录 | 目标父目录不存在即失败（`Io`），不自动递归建目录 |
| 长度快照 | 传输过程中源文件被改写会触发「写出字节数与声明不符」→ `Http` 错误 |
| 超时 | `WebdavConfig::timeout_ms` 覆盖「建连 → 写头 → 写完整个请求体 → 响应头」；大文件需调大或设 `None` |

### 条件请求与乐观并发

上传 / 下载 / 删除 / 移动 / 复制 / 属性操作都可用 `Conditions` 防竞态：

```moonbit
let put = client.put_file(path="/d.txt", data=bytes,
  conditions=@webdav.Conditions::new(if_none_match="*")) // 仅当不存在时创建
let got = client.get_file(path="/d.txt",
  conditions=@webdav.Conditions::new(if_match=put.etag.unwrap()))
```

`put_file` / `get_file` 把 ETag 带在结果里，正好喂给下一次的 `if_match`。

### 取消

```moonbit
let controller = @webdav.AbortController::new()
let task = client.download_file(path="/big.bin", on_chunk=fn(_) { ... }, signal=controller.signal())
controller.abort(reason="用户中断")
```

取消后抛 `WebdavError::Cancelled(reason?)`；`reason` 透传 `AbortSignal::reason()`。
路径形态（`put_file_from_path` / `download_to_path`）同样接受 `signal?`；
取消落在流式泵的块与块之间或挂起的读写上都会立刻断开，
`download_to_path` 被取消时本地留下部分内容（见上表）。

### 属性（死属性）命名空间

自定义属性需要一个 XML 命名空间，默认 `DEFAULT_PROP_NS`
（`urn:q2316367743:webdav:prop`），可用 `ns_uri` 覆盖。属性名必须是合法 XML 名
（非法时 `Api(400)`）。

服务端未存储的属性：`get_properties` 直接过滤掉；需要知道「为什么没有」时用
`get_properties_with_status`（该属性的 `status == 404`）。

### 部分失败（207）

DELETE / MOVE / COPY 在服务端返回 207 且部分条目失败（非 2xx）时抛
`WebdavError::Partial(operation, failures)`；全部成功则正常返回。
`failures` 里每项含服务端 href、状态码与中文注解。

### HEAD 回退

`exists` 先用 HEAD；服务端返回 405（方法不允许）或 501（未实现）时，
自动改用 PROPFIND `Depth:0` 判断存在性（404 → false）。
304 → true（配合 `if_none_match` 使用）。

### 错误状态码语义（message 中文注解）

常见映射：401 未认证（查凭据）、403 无权限、404 不存在、405 目标已存在
（MKCOL）或方法不支持、409 父目录不存在（MKCOL）、412 目标存在且不允许覆盖
（MOVE/COPY overwrite=false）、423 资源被锁定、507 存储空间不足。
