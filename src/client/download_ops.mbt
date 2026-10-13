// 文件下载的三种形态，共用一条 GET 开流管线（`open_get_stream`）：
// - `get_file`：全量读进内存，返回内容与响应元数据；
// - `download_file`：同步分块回调，调用方自己消费字节；
// - `download_to_path`：直接流式写本地文件（写盘是 async，只能在内部做，
//   同步 `on_chunk` 回调里 await 不了，这正是它存在的理由）。
// 三者都支持 `range?`（RFC 7233 区间下载，服务端接受时回 206）；
// 断点续传在 download_resume.mbt。上传实现按方向拆到 file_ops.mbt（RL-04）。

///|
/// 下载文件到内存（GET），返回内容与响应元数据
/// （Content-Type / Content-Length / ETag / Last-Modified）。
/// `on_progress` 由 moonhttp 在读响应体过程中触发。
///
/// - `range`：区间下载（RFC 7233）。提供则发 `Range` 头，服务端支持时
///   回 206、`content` 只是区间内容，`content_range` 携带解析结果；
///   服务端忽略 Range 回 200 时返回全量（调用方以 `status` 区分）。
pub async fn WebdavClient::get_file(
  self : WebdavClient,
  path~ : String,
  range? : @types.ByteRange,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> @types.GetResult raise @types.WebdavError {
  let url = self.url_for(path)
  let mut cfg = apply_conditions(
    @config.Config::new(url).with_method(@config.Method::Get),
    conditions,
    operation="GET",
    url~,
  )
  match range {
    Some(range) => cfg = cfg.with_header("Range", range.header_value())
    None => ()
  }
  match adapt_progress(on_progress) {
    Some(report) => cfg = cfg.with_on_download_progress(report)
    None => ()
  }
  let response = self.perform(cfg, signal?)
  // 带 Range 的请求允许 206（部分内容）；服务端也可能忽略 Range 回 200 全量
  let ok = if range is Some(_) { [200, 206] } else { [200] }
  let checked = check_status(response, operation="GET", ok~)
  {
    content: checked.bytes(),
    status: checked.status,
    content_type: checked.headers.get("Content-Type"),
    content_length: read_content_length(checked.headers),
    etag: checked.headers.get("ETag"),
    last_modified: checked.headers.get("Last-Modified"),
    content_range: parse_content_range_header(checked.headers),
  }
}

///|
/// 流式下载（GET 分块消费）：每个分块交给 `on_chunk`（如逐块写文件），
/// 读完即止，内存占用与文件大小无关。
///
/// - `chunk_size`：单次读取上限，默认 64 KiB；
/// - `range`：区间下载（RFC 7233），只消费服务端返回的区间内容；
///   进度按**本次响应**计（`total` 取响应 Content-Length，206 时是区间长度）；
/// - `on_progress`：按已接收字节累计触发，`total` 来自 Content-Length
///   （服务端未返回长度时为 `None`）；
/// - `on_chunk` 是**同步**回调：只适合内存消费（拼接 Buffer、算哈希、
///   喂同步通道）。要落盘或做别的 async 副作用，用 `download_to_path`。
pub async fn WebdavClient::download_file(
  self : WebdavClient,
  path~ : String,
  on_chunk~ : (Bytes) -> Unit,
  chunk_size? : Int32,
  range? : @types.ByteRange,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let size = download_chunk_size(chunk_size)
  let stream = self.open_get_stream(path~, range?, conditions?, signal?)
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

///|
/// 流式下载到本地文件：边收边写盘，内存占用与文件大小无关。
/// 与 `put_file_from_path` 对称，是「下载到磁盘」的正路——
/// 同步 `on_chunk` 回调里没法 await 写文件。
///
/// - `path`：服务端源路径；`local_path`：本地目标文件（已存在则截断覆盖）；
/// - `chunk_size`：单次读取 / 写入上限，默认 64 KiB；
/// - `range`：区间下载（RFC 7233），服务端接受时只写区间内容，
///   进度按本次响应计（206 时 `total` 是区间长度）；
/// - 顺序上**先发请求、拿到 200 / 206 才建本地文件**：404 等失败不会
///   清空本地已存在的同名文件；
/// - 本地文件创建 / 写入失败抛 `WebdavError::Io`；读流失败经统一映射
///   （取消 → `Cancelled`，其余 → `Http`）；
/// - 失败或取消时可能留下**部分内容**的本地文件（不自动删除）——
///   需要从中断处继续时用 `download_to_path_resume`；
/// - `on_progress`：按已写入字节累计触发，`total` 来自 Content-Length
///   （服务端未返回长度时为 `None`）。
pub async fn WebdavClient::download_to_path(
  self : WebdavClient,
  path~ : String,
  local_path~ : String,
  chunk_size? : Int32,
  range? : @types.ByteRange,
  conditions? : @types.Conditions,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let size = download_chunk_size(chunk_size)
  let stream = self.open_get_stream(path~, range?, conditions?, signal?)
  let total = read_content_length(stream.headers)
  write_stream_to_file(
    stream,
    local_path~,
    append=false,
    offset=0,
    total~,
    chunk_size=size,
    on_progress?,
    signal?,
  )
}

///|
/// 打开 GET 流：组装请求、发流式请求、校验状态码。带 `range` 时允许
/// 206（部分内容，服务端也可能忽略 Range 回 200 全量），否则维持
/// 「非 200 即错」；失败先关闭流再抛 `Api`（不把连接漏在那儿），
/// 是两条流式下载路径的公共前缀。
async fn WebdavClient::open_get_stream(
  self : WebdavClient,
  path~ : String,
  range? : @types.ByteRange,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> @moonhttp.StreamResponse raise @types.WebdavError {
  let url = self.url_for(path)
  let mut cfg = apply_conditions(
    @config.Config::new(url).with_method(@config.Method::Get),
    conditions,
    operation="GET",
    url~,
  )
  match range {
    Some(range) => cfg = cfg.with_header("Range", range.header_value())
    None => ()
  }
  let stream = self.http.stream(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
  let ok = if range is Some(_) { [200, 206] } else { [200] }
  if !ok.contains(stream.status) {
    let status = stream.status
    stream.close()
    raise @types.WebdavError::api(
      status~,
      operation="GET",
      message=status_message(status),
    )
  }
  stream
}

///|
/// 把 GET 响应流写进本地文件：`append=false` 截断覆盖（200 全量），
/// `append=true` 追加续写（206 续传）。进度按 `offset` 起累计到
/// `total`。流与文件在收尾时总是成对关闭，读流失败经统一映射。
async fn write_stream_to_file(
  stream : @moonhttp.StreamResponse,
  local_path~ : String,
  append~ : Bool,
  offset~ : Int32,
  total~ : Int32?,
  chunk_size~ : Int32,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let file = if append {
    @fs.open(
      local_path,
      mode=@fs.Mode::WriteOnly,
      append=true,
      create_mode=@fs.CreateMode::OpenOrCreate,
    ) catch {
      error => {
        stream.close()
        raise @types.WebdavError::io(
          message="打开本地文件续写失败（\{local_path}）：\{error}",
        )
      }
    }
  } else {
    @fs.create(local_path, allow_existing=true) catch {
      error => {
        stream.close()
        raise @types.WebdavError::io(
          message="创建本地文件失败（\{local_path}）：\{error}",
        )
      }
    }
  }
  let mut loaded = offset
  let outcome : Result[Unit, @types.WebdavError] = try {
    while true {
      let chunk = stream.read_some(max_len=chunk_size) catch {
        error => raise map_http_error(error, signal_reason(signal))
      }
      match chunk {
        Some(bytes) => {
          file.write(bytes) catch {
            error =>
              raise @types.WebdavError::io(
                message="写入本地文件失败（\{local_path}）：\{error}",
              )
          }
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
  file.close()
  stream.close()
  match outcome {
    Ok(_) => ()
    Err(error) => raise error
  }
}

///|
/// 206 响应的 `Content-Range` 解析：缺失或形态不符为 `None`。
fn parse_content_range_header(
  headers : @moonhttp.Headers,
) -> @types.ContentRange? {
  match headers.get("Content-Range") {
    Some(text) => @types.parse_content_range(text)
    None => None
  }
}

///|
/// 流式下载的分块大小：`None` / 非正数一律取默认 64 KiB。
fn download_chunk_size(chunk_size : Int32?) -> Int32 {
  match chunk_size {
    Some(value) if value > 0 => value
    _ => 64 * 1024
  }
}

///|
/// 从响应头取 Content-Length（缺失或非数字时为 `None`）。
fn read_content_length(headers : @moonhttp.Headers) -> Int32? {
  match headers.get("Content-Length") {
    Some(text) => @types.parse_ascii_int(text)
    None => None
  }
}
