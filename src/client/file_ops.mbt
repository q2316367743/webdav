// 文件上传的三种形态，共用一条 PUT 管线（`send_put`）：
// - `put_file`：入参是已在内存的完整 Bytes（BytesReader 拉取式供给）；
// - `put_file_stream`：入参是任意 `@io.Reader`，边读边发；
// - `put_file_from_path`：入参是本地文件路径，内部打开 / 取长度 / 边读边发 / 关闭。
// 三者都经 moonhttp 0.5 的流式请求体发送：声明长度走定长 Content-Length，
// 长度未知走 chunked；传输层每 64 KiB 分块触发上传进度。
// 下载实现按方向拆到 download_ops.mbt（RL-04）。

///|
/// Bytes 的拉取式读取流：把已在内存的文件内容按块交给传输层，
/// 不引入协程与管道、也不拷贝整份数据（视图切片直接供给泵循环）。
/// 单次上传独占一个实例，光标走到尾部即 EOF。
priv struct BytesReader {
  data : Bytes
  mut pos : Int
  // read_some 复用这块内部缓冲做中转，须与实例同生命周期
  buf : @io.ReaderBuffer
}

///|
impl @io.Reader for BytesReader with fn _get_internal_buffer(self) {
  self.buf
}

///|
impl @io.Reader for BytesReader with fn _direct_read(
  self,
  dst,
  offset~,
  max_len~,
) -> Int {
  let remaining = self.data.length() - self.pos
  if remaining <= 0 {
    return 0
  }
  let n = if max_len < remaining { max_len } else { remaining }
  dst.blit_from_bytesview(offset, self.data[self.pos:self.pos + n])
  self.pos = self.pos + n
  n
}

///|
/// 上传文件（PUT 整体写入），返回响应元数据（ETag / Last-Modified /
/// Location），可直接用于后续的条件请求。
///
/// 这是**全量字节**形态：`data` 契约是「完整内容已在内存」。上传过程
/// 本身是流式的（不额外整份拷贝），但内容要先在调用方内存里；内容在磁盘、
/// 或大到不想整块驻留时，用 `put_file_from_path` / `put_file_stream`。
///
/// - `data`：完整文件内容，包装成流式请求体发送；
/// - `content_type`：可选 MIME 类型；
/// - `conditions`：可选 `If-Match` / `If-None-Match`（乐观并发控制，
///   如 `If-None-Match: "*"` 表示「仅当资源不存在时才创建」）；
/// - `on_progress`：上传进度，按传输层 64 KiB 分块节奏触发，
///   `total` 为声明的请求体长度。
pub async fn WebdavClient::put_file(
  self : WebdavClient,
  path~ : String,
  data~ : Bytes,
  content_type? : String,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.PutResult raise @types.WebdavError {
  let reader = BytesReader::{ data, pos: 0, buf: @io.ReaderBuffer::new(), }
  self.send_put(
    path~,
    reader~,
    content_length=data.length(),
    content_type?,
    conditions?,
    on_progress?,
    signal?,
  )
}

///|
/// 流式上传：数据源是任意读取流（`&@io.Reader`），传输层边读边写，
/// 请求体不再需要整块驻留内存。
///
/// - `reader`：拉取式读取流。`read_some` 返回 `None`（EOF）即请求体收尾。
///   `@fs.File`（本地文件）、`@io.MemoryReader`（边生成边推）、
///   `@io.pipe()` 的读端（生产者协程）都能直接接；
/// - `content_length`：请求体长度。给了走定长 `Content-Length`（进度
///   `total` 已知，兼容 HTTP/1.0 目标）；不给走 `Transfer-Encoding: chunked`。
///   写出字节数与声明不符时传输层报错（本地数据与声明对不上）；
/// - 其余参数语义与 `put_file` 一致。
///
/// **流是一次性资源**：同一条流不要发两次请求；遇到 307/308 这类要求
/// 原样重放请求体的重定向时，moonhttp 会直接报错而不是静默发空体。
pub async fn WebdavClient::put_file_stream(
  self : WebdavClient,
  path~ : String,
  reader~ : &@io.Reader,
  content_length? : Int,
  content_type? : String,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.PutResult raise @types.WebdavError {
  self.send_put(
    path~,
    reader~,
    content_length?,
    content_type?,
    conditions?,
    on_progress?,
    signal?,
  )
}

///|
/// 从本地文件路径流式上传：内部打开文件、用文件长度声明
/// `Content-Length`、把文件句柄当读取流交给传输层，边读边发，
/// 成功或失败都关闭句柄——**内容不整份读进内存**。
///
/// - `path`：服务端目标路径；`local_path`：本地待上传文件的绝对 / 相对路径；
/// - 本地文件打不开、路径是目录时抛 `WebdavError::Io`，此时不会发出任何请求；
/// - 其余参数语义与 `put_file` 一致（`on_progress` 的 `total` 为文件长度）。
///
/// 注意：长度在打开时取快照，传输过程中文件被改写会导致
/// 「写出字节数与声明不符」，传输层报 `Http` 错误；大文件的整跳超时见
/// `WebdavConfig::timeout_ms`（覆盖「建连 → 写完整个请求体 → 响应头」）。
pub async fn WebdavClient::put_file_from_path(
  self : WebdavClient,
  path~ : String,
  local_path~ : String,
  content_type? : String,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.PutResult raise @types.WebdavError {
  let (file, size) = open_local_source(local_path)
  let outcome : Result[@types.PutResult, @types.WebdavError] = Ok(
    self.send_put(
      path~,
      reader=file,
      content_length=size,
      content_type?,
      conditions?,
      on_progress?,
      signal?,
    ),
  ) catch {
    error => Err(error)
  }
  file.close()
  match outcome {
    Ok(result) => result
    Err(error) => raise error
  }
}

///|
/// PUT 管线的公共实现：三种上传形态只差「数据从哪来」——请求头、
/// 条件请求、进度接线与状态码判定完全一致，不重复三份。
async fn WebdavClient::send_put(
  self : WebdavClient,
  path~ : String,
  reader~ : &@io.Reader,
  content_length? : Int,
  content_type? : String,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.PutResult raise @types.WebdavError {
  let mut cfg = @config.Config::new(self.url_for(path))
    .with_method(@config.Method::Put)
    .with_data_from_stream(reader, content_length?)
  match content_type {
    Some(mime) => cfg = cfg.with_header("Content-Type", mime)
    None => ()
  }
  cfg = apply_conditions(cfg, conditions)
  match adapt_progress(on_progress) {
    Some(report) => cfg = cfg.with_on_upload_progress(report)
    None => ()
  }
  let response = self.http.request(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
  let checked = check_status(response, operation="PUT", ok=[200, 201, 204])
  {
    status: checked.status,
    created: checked.status == 201,
    etag: checked.headers.get("ETag"),
    last_modified: checked.headers.get("Last-Modified"),
    location: checked.headers.get("Location"),
  }
}

///|
/// 打开本地文件作为上传数据源：返回（文件句柄，字节长度）。
/// 打不开、或路径是目录，都抛 `Io`（调用方据此定位本地问题，
/// 而不是把它当成服务端返回的错误）。
async fn open_local_source(
  local_path : String,
) -> (@fs.File, Int) raise @types.WebdavError {
  let file = @fs.open(local_path, mode=@fs.Mode::ReadOnly) catch {
    error =>
      raise @types.WebdavError::io(
        message="打开本地文件失败（\{local_path}）：\{error}",
      )
  }
  if file.kind() == @fs.FileKind::Directory {
    file.close()
    raise @types.WebdavError::io(
      message="本地路径是目录，不能作为上传数据源：\{local_path}",
    )
  }
  let size = file.size() catch {
    error => {
      file.close()
      raise @types.WebdavError::io(
        message="读取本地文件长度失败（\{local_path}）：\{error}",
      )
    }
  }
  (file, size.to_int())
}
