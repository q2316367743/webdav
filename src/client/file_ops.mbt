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
/// 上传文件（PUT 整体写入）。
///
/// - `data`：完整文件内容，包装成流式请求体发送；
/// - `content_type`：可选 MIME 类型；
/// - `on_progress`：上传进度，按传输层 64 KiB 分块节奏触发，
///   `total` 为声明的请求体长度。
pub async fn WebdavClient::put_file(
  self : WebdavClient,
  path~ : String,
  data~ : Bytes,
  content_type? : String,
  on_progress? : (@types.Progress) -> Unit,
) -> Unit raise @types.WebdavError {
  let reader = BytesReader::{ data, pos: 0, buf: @io.ReaderBuffer::new(), }
  let mut cfg = @config.Config::new(self.url_for(path))
    .with_method(@config.Method::Put)
    .with_data_from_stream(reader, content_length=data.length())
  match content_type {
    Some(mime) => cfg = cfg.with_header("Content-Type", mime)
    None => ()
  }
  match adapt_progress(on_progress) {
    Some(report) => cfg = cfg.with_on_upload_progress(report)
    None => ()
  }
  let response = self.http.request(cfg) catch {
    error => raise @types.WebdavError::http(error)
  }
  ignore(check_status(response, operation="PUT", ok=[200, 201, 204]))
}

///|
/// 下载文件到内存（GET 全量读取）。
/// `on_progress` 由 moonhttp 在读响应体过程中触发。
pub async fn WebdavClient::get_file(
  self : WebdavClient,
  path~ : String,
  on_progress? : (@types.Progress) -> Unit,
) -> Bytes raise @types.WebdavError {
  let mut cfg = @config.Config::new(self.url_for(path)).with_method(
    @config.Method::Get,
  )
  match adapt_progress(on_progress) {
    Some(report) => cfg = cfg.with_on_download_progress(report)
    None => ()
  }
  let response = self.http.request(cfg) catch {
    error => raise @types.WebdavError::http(error)
  }
  check_status(response, operation="GET", ok=[200]).bytes()
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
  on_progress? : (@types.Progress) -> Unit,
) -> Unit raise @types.WebdavError {
  let size = if chunk_size.unwrap_or(0) > 0 {
    chunk_size.unwrap()
  } else {
    64 * 1024
  }
  let cfg = @config.Config::new(self.url_for(path)).with_method(
    @config.Method::Get,
  )
  let stream = self.http.stream(cfg) catch {
    error => raise @types.WebdavError::http(error)
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
  let total = match stream.headers.get("Content-Length") {
    Some(text) => @types.parse_ascii_int(text)
    None => None
  }
  let mut loaded = 0
  let outcome : Result[Unit, @types.WebdavError] = try {
    while true {
      let chunk = stream.read_some(max_len=size) catch {
        error => raise @types.WebdavError::http(error)
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
