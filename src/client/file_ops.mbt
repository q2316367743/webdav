// 文件上传与下载。上传走 moonhttp 0.5 的流式请求体：内存 Bytes 由
// BytesReader 以拉取方式按块供给，定长 Content-Length 分帧，传输层边读
// 边写、每 64 KiB 分块触发上传进度；下载提供全量（get_file）与流式分块
// 消费（download_file）两种形态。

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
  let mut cfg = @config.Config::new(self.url_for(path))
    .with_method(@config.Method::Put)
    .with_data_from_stream(reader, content_length=data.length())
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
/// 下载文件到内存（GET 全量读取），返回内容与响应元数据
/// （Content-Type / Content-Length / ETag / Last-Modified）。
/// `on_progress` 由 moonhttp 在读响应体过程中触发。
pub async fn WebdavClient::get_file(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.GetResult raise @types.WebdavError {
  let mut cfg = apply_conditions(
    @config.Config::new(self.url_for(path)).with_method(@config.Method::Get),
    conditions,
  )
  match adapt_progress(on_progress) {
    Some(report) => cfg = cfg.with_on_download_progress(report)
    None => ()
  }
  let response = self.http.request(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
  let checked = check_status(response, operation="GET", ok=[200])
  {
    content: checked.bytes(),
    status: checked.status,
    content_type: checked.headers.get("Content-Type"),
    content_length: read_content_length(checked.headers),
    etag: checked.headers.get("ETag"),
    last_modified: checked.headers.get("Last-Modified"),
  }
}

///|
/// 从响应头取 Content-Length（缺失或非数字时为 `None`）。
fn read_content_length(headers : @moonhttp.Headers) -> Int? {
  match headers.get("Content-Length") {
    Some(text) => @types.parse_ascii_int(text)
    None => None
  }
}

///|
/// 流式下载（GET 分块消费）：每个分块交给 `on_chunk`（如逐块写文件），
/// 读完即止，内存占用与文件大小无关。
///
/// - `chunk_size`：单次读取上限，默认 64 KiB；
/// - `on_progress`：按已接收字节累计触发，`total` 来自 Content-Length
///   （服务端未返回长度时为 `None`）。
pub async fn WebdavClient::download_file(
  self : WebdavClient,
  path~ : String,
  on_chunk~ : (Bytes) -> Unit,
  chunk_size? : Int,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let size = if chunk_size.unwrap_or(0) > 0 {
    chunk_size.unwrap()
  } else {
    64 * 1024
  }
  let cfg = apply_conditions(
    @config.Config::new(self.url_for(path)).with_method(@config.Method::Get),
    conditions,
  )
  let stream = self.http.stream(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
  if stream.status != 200 {
    let status = stream.status
    stream.close()
    raise @types.WebdavError::api(
      status~,
      operation="GET",
      message=status_message(status),
    )
  }
  let total = read_content_length(stream.headers)
  let mut loaded = 0
  let outcome : Result[Unit, @types.WebdavError] = try {
    while true {
      let chunk = stream.read_some(max_len=size) catch {
        error => raise map_http_error(error, signal_reason(signal))
      }
      match chunk {
        Some(bytes) => {
          on_chunk(bytes)
          loaded = loaded + bytes.length()
          match on_progress {
            Some(report) => report({ loaded, total, })
            None => ()
          }
        }
        None => break
      }
    }
    Ok(())
  } catch {
    error => Err(error)
  }
  stream.close()
  match outcome {
    Ok(_) => ()
    Err(error) => raise error
  }
}
