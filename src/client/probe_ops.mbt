// 能力探测与存在性判断：OPTIONS 探测服务端能力（DAV 等级 / Allow / Server），
// HEAD 不被支持时回落到 PROPFIND Depth:0 的 exists。单独成文件（RL-04）。

///|
/// 探测服务端能力（OPTIONS）：返回 `DAV` 合规等级、`Allow` 方法列表与
/// `Server` 标识，便于在 LOCK / MKCOL / MOVE 等操作前判断服务端支持面，
/// 而不是靠失败状态码猜。
///
/// `path` 省略时探测根路径（服务端通常会回全局能力）。
pub async fn WebdavClient::options(
  self : WebdavClient,
  path? : String,
  signal? : @moonhttp.AbortSignal,
) -> @types.ServerCapabilities raise @types.WebdavError {
  let target = match path {
    Some(value) => value
    None => "/"
  }
  let response = self.send(
    operation="OPTIONS",
    http_method=@config.Method::Options,
    path=target,
    ok=[200, 204],
    signal?,
  )
  {
    dav_class: parse_dav_class(response.headers.get("DAV")),
    allow: parse_allow(response.headers.get("Allow")),
    server: response.headers.get("Server"),
  }
}

///|
/// 资源是否存在。
///
/// 优先用 HEAD（比 PROPFIND 轻，不返回响应体）：200 / 204 存在、404 不存在、
/// 304 表示条件命中（资源存在且未变）。若服务端不支持 HEAD（405 / 501，
/// 部分对象存储与精简实现如此），回落到 PROPFIND Depth:0：207 存在、
/// 404 不存在。
pub async fn WebdavClient::exists(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Bool raise @types.WebdavError {
  let response = self.send(
    operation="HEAD",
    http_method=@config.Method::Head,
    path~,
    conditions?,
    signal?,
    ok=[200, 204, 304, 404, 405, 501],
  )
  let status = response.status
  if status == 405 || status == 501 {
    return self.exists_by_propfind(path~, conditions?, signal?)
  }
  status == 200 || status == 204 || status == 304
}

///|
/// `exists` 的回退路径：PROPFIND Depth:0，207 视为存在、404 视为不存在。
async fn WebdavClient::exists_by_propfind(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Bool raise @types.WebdavError {
  let outcome : Result[Unit, @types.WebdavError] = try {
    ignore(
      self.send_propfind(
        path~,
        depth=@types.Depth::Zero,
        body=@xmlutil.propfind_allprop_body(),
        conditions?,
        signal?,
      ),
    )
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => true
    Err(error) =>
      match error.detail() {
        Api(status=404, operation=_, message=_) => false
        _ => raise error
      }
  }
}

///|
/// 解析 `DAV` 响应头（形如 `1, 2` 或 `1,2` 或 `1, 2, extended-mkcol`）
/// 里的合规等级数字，非数字 token 忽略。
/// 没有该头时按 RFC 4918 §10.1 视为 Class 1。
fn parse_dav_class(header : String?) -> Array[Int] {
  let levels : Array[Int] = []
  match header {
    Some(text) =>
      for segment in text.split(",") {
        match @types.parse_ascii_int(segment.trim().to_owned()) {
          Some(level) => levels.push(level)
          None => ()
        }
      }
    None => ()
  }
  if levels.length() == 0 {
    levels.push(1)
  }
  levels
}

///|
/// 解析 `Allow` 响应头的方法名列表：去空白、ASCII 大写，保持出现顺序。
fn parse_allow(header : String?) -> Array[String] {
  let methods : Array[String] = []
  match header {
    Some(text) =>
      for segment in text.split(",") {
        let item = segment.trim()
        if item.length() > 0 {
          methods.push(@types.ascii_upper(item.to_owned()))
        }
      }
    None => ()
  }
  methods
}
