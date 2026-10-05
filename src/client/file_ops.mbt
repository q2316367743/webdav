// 文件上传与下载。上传是整体 PUT（moonhttp 0.4 请求体为一次性字节，
// 其分块写出的节奏即为上传进度）；下载提供全量（get_file）与
// 流式分块消费（download_file）两种形态。

///|
/// 二进制请求体装饰器：moonhttp 0.4 的 Config 只能从 String 构造请求体，
/// 这里在传输层入口把请求的 body 替换为真实 Bytes。
/// Content-Length 与上传进度都由传输层按替换后的 body 计算，天然一致；
/// moonhttp 支持流式请求体后本类型可整体移除。
priv struct BinaryBodyTransport {
  inner : &@transport.Transport
  data : Bytes
  on_progress : ((@config.ProgressEvent) -> Unit)?
}

///|
impl @transport.Transport for BinaryBodyTransport with fn send(self, request) {
  self.inner.send({
    ..request,
    body: Some(self.data),
    on_upload_progress: self.on_progress,
  })
}

///|
/// 上传文件（PUT 整体写入）。
///
/// - `data`：完整文件内容（moonhttp 支持流式请求体之前，上传是全量传输）；
/// - `content_type`：可选 MIME 类型；
/// - `on_progress`：上传进度，按传输层 64 KiB 分块节奏触发。
pub async fn WebdavClient::put_file(
  self : WebdavClient,
  path~ : String,
  data~ : Bytes,
  content_type? : String,
  on_progress? : (@types.Progress) -> Unit,
) -> Unit raise @types.WebdavError {
  let transport = BinaryBodyTransport::{
    inner: self.transport,
    data,
    on_progress: adapt_progress(on_progress),
  }
  let client = @moonhttp.Client::new(config=self.defaults, transport~)
  let mut cfg = @config.Config::new(self.url_for(path)).with_method(
    @config.Method::Put,
  )
  match content_type {
    Some(mime) => cfg = cfg.with_header("Content-Type", mime)
    None => ()
  }
  let response = client.request(cfg) catch {
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
