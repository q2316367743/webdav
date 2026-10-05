# API 参考

对外 API 统一经根包门面（`@webdav`）访问；类型与方法随 `create_webdav_client`
返回的 `WebdavClient` 使用。全部网络方法是 `async ... raise WebdavError`。

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
| `name` | String | href 末段 percent 解码后的显示名 |
| `is_dir` | Bool | 是否目录（collection） |
| `content_length` | Int? | 字节大小；目录 / 未知为 None |
| `content_type` | String? | MIME 类型 |
| `last_modified` | String? | RFC 1123 原样 |
| `created` | String? | RFC 3339 原样 |
| `etag` | String? | 含引号原样 |

### Progress（进度快照）

`{ loaded : Int, total : Int? }`；`percent() -> Double?` 返回 `0.0 ~ 1.0`
（总长未知 / 为零时 `None`）。

### WebdavError（统一错误，suberror）

```moonbit
match error.detail() {
  Http(http_error) => ...            // 网络 / HTTP 协议层（moonhttp）
  Xml(xml_error)   => ...            // 207 响应解析失败
  Api(status~, operation~, message~) => ... // 非期望状态码（中文消息）
}
```

`error.to_string()` 得中文人读描述；实现了 `Show`，可直接 `println("\{error}")`。
便捷构造：`WebdavError::http / xml / api`（供扩展实现复用）。

## 方法一览（全部 `async raise WebdavError`）

| 方法 | 签名要点 | 说明 |
|------|---------|------|
| `put_file` | `path~ : String, data~ : Bytes, content_type? : String, on_progress? : (Progress) -> Unit` | PUT 整体上传 |
| `get_file` | `path~ : String, on_progress?` | GET 全量下载到内存 |
| `download_file` | `path~ : String, on_chunk~ : (Bytes) -> Unit, chunk_size? : Int, on_progress?` | 流式分块下载 |
| `mkdir` | `path~ : String` | MKCOL 单级建目录 |
| `delete` | `path~ : String` | DELETE |
| `exists` | `path~ : String` -> Bool | HEAD 探测 |
| `list` | `path~ : String` -> Array[FileInfo] | Depth:1，不含自身 |
| `stat` | `path~ : String` -> FileInfo | Depth:0 |
| `move_path` | `src~ : String, dst~ : String, overwrite? : Bool`（默认 true） | MOVE |
| `copy_path` | 同 `move_path` | COPY |
| `set_properties` | `path~ : String, props~ : Array[(String, String)], ns_uri? : String` | PROPPATCH set |
| `get_properties` | `path~ : String, names~ : Array[String], ns_uri? : String` -> Map[String, String] | 按名 PROPFIND |

## 语义细节

### 路径

- `path` 相对 `base_url`，建议以 `/` 开头（会自动补）；
- 中文、空格等自动 percent 编码（空格 → `%20`），无需调用方预处理；
- `move_path` / `copy_path` 的 `dst` 是路径（非完整 URL），客户端负责拼绝对 Destination。

### 进度回调节奏

- 上传：moonhttp 传输层按 64 KiB 分块写、逐块回调（真实网络进度）；
- `get_file`：moonhttp 读响应体时分块回调；
- `download_file`：每收到一个 chunk 回调一次（`total` 来自 Content-Length，无长度时 `None`）；
- Mock 传输层不写连接，上传进度不触发（黑盒测试断言了这一点）。

### 流式上传限制与升级预留

moonhttp 0.4 的请求体是一次性字节，`put_file` 因此接受完整 `Bytes`（全量传输，
内存占用 = 文件大小）。实现上通过 `BinaryBodyTransport` 装饰器在传输层注入
Bytes。moonhttp 支持流式请求体后：

1. 删除 `src/client/file_ops.mbt` 中的 `BinaryBodyTransport`；
2. `put_file` 改为 moonhttp 的流式 body 配置（或追加 `put_file_stream` 方法），
   签名与进度语义保持不变。

### 属性（死属性）命名空间

自定义属性需要一个 XML 命名空间，默认 `DEFAULT_PROP_NS`
（`urn:q2316367743:webdav:prop`），可用 `ns_uri` 覆盖。属性名必须是合法 XML 名
（非法时 `Api(400)`）。服务端未存储的属性不出现在 `get_properties` 结果中。

### 错误状态码语义（message 中文注解）

常见映射：401 未认证（查凭据）、403 无权限、404 不存在、405 目标已存在
（MKCOL）或方法不支持、409 父目录不存在（MKCOL）、412 目标存在且不允许覆盖
（MOVE/COPY overwrite=false）、423 资源被锁定、507 存储空间不足。
