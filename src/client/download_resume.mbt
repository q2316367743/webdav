// 断点续传下载：利用 `download_to_path`「失败残留部分文件」的现状，
// 以本地已有字节数为起点发 `Range: bytes=N-` 只拉剩余部分；
// 配 `If-Range` 校验服务端资源未变，变了就整体重写，不拼出损坏文件。
// 底层区间下载在 download_ops.mbt（RL-04 按职责拆文件）。

///|
/// 断点续传下载到本地文件：本地已有前 N 字节（上次中断的残留）时发
/// `Range: bytes=N-` 续传，只拉取剩余部分追加到文件尾；本地不存在 /
/// 为空时等同于 `download_to_path` 全量下载。
///
/// - `etag`：上次响应的 ETag（`get_file` / `put_file` 的结果里都有）。
///   提供则随请求发 `If-Range`：服务端资源仍是这一版才回 206 续传，
///   已被修改则回 200 全文，本方法自动截断重写，保证不拼出损坏文件；
///   省略则裸续传（服务端文件在两次下载之间被整体替换时可能得到
///   拼接损坏的结果，调用方自行权衡）；
/// - 206 的 `Content-Range` 缺失、或区间起点与本地字节数不符时抛
///   `Api`（此时继续追加不安全）；
/// - 416（区间不满足）且本地字节数恰为服务端告知的资源总长时，
///   视为「本地已完整」直接成功返回；否则抛 `Api(416)`；
/// - 下载完成后校验本地文件大小与服务端总长一致（总长已知时），
///   不一致抛 `Api`，保证「成功返回 = 文件完整」；
/// - `on_progress` 报告**绝对**进度：`loaded` 从本地已有字节起累计，
///   `total` 为资源总长（`Content-Range` / `Content-Length` 均未给出
///   时为 `None`）。
pub async fn WebdavClient::download_to_path_resume(
  self : WebdavClient,
  path~ : String,
  local_path~ : String,
  etag? : String,
  chunk_size? : Int32,
  on_progress? : (@types.Progress) -> Unit,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let size = download_chunk_size(chunk_size)
  let offset = resume_offset(local_path)
  if offset == 0 {
    // 没有可续传的本地内容：退化为普通全量下载
    return self.download_to_path(
      path~,
      local_path~,
      chunk_size?,
      on_progress?,
      signal?,
    )
  }
  let url = self.url_for(path)
  let mut cfg = @config.Config::new(url)
    .with_method(@config.Method::Get)
    .with_header("Range", @types.ByteRange::from(start=offset).header_value())
  match etag {
    Some(etag) => cfg = cfg.with_header("If-Range", etag)
    None => ()
  }
  let stream = self.http.stream(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
  if stream.status == 416 {
    // 区间不满足：唯一合法情形是本地已经下完（offset == 资源总长）
    let total = match stream.headers.get("Content-Range") {
      Some(text) => @types.parse_unsatisfied_range_total(text)
      None => None
    }
    stream.close()
    if total is Some(total) && total == offset {
      return
    }
    let hint = match total {
      Some(total) => "本地 \{offset} 字节，服务器总长 \{total} 字节"
      None => "本地 \{offset} 字节，服务器未告知总长"
    }
    raise @types.WebdavError::api(
      status=416,
      operation="GET",
      message="区间不满足（\{hint}）",
    )
  }
  if stream.status == 200 {
    // 服务端忽略 Range（不支持），或 If-Range 判定资源已变更：
    // 只能整体重下，Content-Length 即资源总长
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
    verify_resumed_size(local_path, total)
    return
  }
  if stream.status == 206 {
    match parse_content_range_header(stream.headers) {
      Some(range) if range.first == offset => {
        // 追加续写；进度用绝对值，总长以 Content-Range 为准
        // （206 的 Content-Length 是区间长度，不是资源总长）
        write_stream_to_file(
          stream,
          local_path~,
          append=true,
          offset~,
          total=range.total,
          chunk_size=size,
          on_progress?,
          signal?,
        )
        verify_resumed_size(local_path, range.total)
        return
      }
      Some(range) => {
        stream.close()
        raise @types.WebdavError::api(
          status=206,
          operation="GET",
          message="服务端返回的区间起点（\{range.first}）与本地已有字节数（\{offset}）不符，续传中止",
        )
      }
      None => {
        stream.close()
        raise @types.WebdavError::api(
          status=206,
          operation="GET",
          message="206 响应缺少可解析的 Content-Range 头，无法确认续传区间",
        )
      }
    }
  }
  let status = stream.status
  stream.close()
  raise @types.WebdavError::api(
    status~,
    operation="GET",
    message=status_message(status),
  )
}

///|
/// 续传起点：本地已有字节数；文件不存在按 0（全量下载）。
/// 超出 Int32 表示范围（>2GB）的文件不支持续传，抛 `Io`。
async fn resume_offset(local_path : String) -> Int32 raise @types.WebdavError {
  let exists = @fs.exists(local_path) catch { _ => false }
  if !exists {
    return 0
  }
  let size = @fs.file_size(local_path) catch {
    _ =>
      raise @types.WebdavError::io(
        message="读取本地文件大小失败（\{local_path}）",
      )
  }
  if size > 2147483647L {
    raise @types.WebdavError::io(
      message="本地文件超过 2GB（\{local_path}），不支持断点续传",
    )
  }
  size.to_int()
}

///|
/// 续传完成后的完整性校验：总长已知时本地文件大小必须一致。
async fn verify_resumed_size(
  local_path : String,
  total : Int32?,
) -> Unit raise @types.WebdavError {
  match total {
    None => ()
    Some(total) => {
      let size = @fs.file_size(local_path) catch {
        _ =>
          raise @types.WebdavError::io(
            message="读取本地文件大小失败（\{local_path}）",
          )
      }
      if size != total.to_int64() {
        raise @types.WebdavError::api(
          status=206,
          operation="GET",
          message="下载不完整：本地 \{size} 字节，服务器总长 \{total} 字节",
        )
      }
    }
  }
}
