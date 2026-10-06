// 客户端核心：实例构造、URL 拼接、请求发送与状态检查。

///|
/// WebDAV 客户端：全部操作以方法形式挂在本类型上。
/// 通过 `create_webdav_client` 构造（根包重导出）。
pub struct WebdavClient {
  priv http : @moonhttp.Client
  priv base_url : String
}

///|
/// 规范化根地址：去掉末尾斜杠（"http://h/dav/" → "http://h/dav"）。
fn normalize_base(base : String) -> String {
  if base.has_suffix("/") && base.length() > 1 {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// 从 base_url 提取服务器上的挂载路径前缀：
/// "http://h:8080/dav" → "/dav"，"http://h" → ""。
/// 用于把 PROPFIND 返回的 href 与用户路径对齐。
fn base_path_prefix(base : String) -> String {
  let segments : Array[StringView] = base.split("/").collect()
  if segments.length() <= 3 {
    ""
  } else {
    let buf = StringBuilder()
    for i in 3..<segments.length() {
      buf.write_char('/')
      buf.write_view(segments[i])
    }
    buf.to_string()
  }
}

///|
/// 组装实例级默认配置：认证 / 超时 / 状态码放行（由本层判定）。
fn build_defaults(config : @types.WebdavConfig) -> @config.Config {
  let cfg = @config.Config::default()
    .with_base_url(normalize_base(config.base_url))
    .with_timeout(config.timeout_ms.unwrap_or(@types.DEFAULT_TIMEOUT_MS))
    .with_validate_status(fn(_) { true })
  match config.username {
    Some(user) => cfg.with_auth(user, config.password.unwrap_or(""))
    None => cfg
  }
}

///|
/// 创建 WebDAV 客户端（moonhttp 自研 HTTP/1.1 传输层）。
pub fn create_webdav_client(config : @types.WebdavConfig) -> WebdavClient {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  create_webdav_client_with_transport(config, transport)
}

///|
/// 创建使用指定传输层的客户端：测试注入 MockTransport，
/// 或自定义连接 / 代理行为。
pub fn create_webdav_client_with_transport(
  config : @types.WebdavConfig,
  transport : &@transport.Transport,
) -> WebdavClient {
  let defaults = build_defaults(config)
  {
    http: @moonhttp.Client::new(config=defaults, transport~),
    base_url: normalize_base(config.base_url),
  }
}

///|
/// 拼接请求 URL：规范化后的 base_url + percent 编码后的路径。
fn WebdavClient::url_for(self : WebdavClient, path : String) -> String {
  let normalized = if path.has_prefix("/") { path } else { "/" + path }
  self.base_url + @types.percent_encode_path(normalized)
}

///|
/// 常见 WebDAV 状态码的中文注解（用于 Api 错误消息）。
fn status_message(status : Int) -> String {
  match status {
    200 => "成功"
    201 => "已创建"
    204 => "成功（无响应体）"
    207 => "Multi-Status"
    301 | 302 | 307 | 308 => "重定向"
    400 => "请求不合法"
    401 => "未认证（检查用户名 / 密码）"
    403 => "无权限"
    404 => "资源不存在"
    405 => "方法不允许（目标已存在或服务器不支持该操作）"
    409 => "冲突（父目录不存在？）"
    412 => "前置条件失败（目标已存在且不允许覆盖？）"
    423 => "资源被锁定"
    502 | 504 => "网关错误"
    507 => "存储空间不足"
    _ => "服务端返回异常状态"
  }
}

///|
/// 校验响应状态码：不在 ok 集合内则抛 `Api` 错误。
fn check_status(
  response : @moonhttp.Response,
  operation~ : String,
  ok~ : Array[Int],
) -> @moonhttp.Response raise @types.WebdavError {
  if ok.contains(response.status) {
    response
  } else {
    raise @types.WebdavError::api(
      status=response.status,
      operation~,
      message=status_message(response.status),
    )
  }
}

///|
/// 发送文本请求体（或无请求体）的请求并校验状态码。
/// XML 类操作（PROPFIND / PROPPATCH）走这里。
async fn WebdavClient::send(
  self : WebdavClient,
  operation~ : String,
  http_method~ : @config.Method,
  path~ : String,
  headers? : Array[(String, String)],
  body? : String,
  ok~ : Array[Int],
) -> @moonhttp.Response raise @types.WebdavError {
  let mut cfg = @config.Config::new(self.url_for(path)).with_method(http_method)
  match headers {
    Some(pairs) =>
      for pair in pairs {
        let (name, value) = pair
        cfg = cfg.with_header(name, value)
      }
    None => ()
  }
  match body {
    Some(xml) => cfg = cfg.with_data_from_str(xml)
    None => ()
  }
  let response = self.http.request(cfg) catch {
    error => raise @types.WebdavError::http(error)
  }
  check_status(response, operation~, ok~)
}

///|
/// 把对外的 `Progress` 回调适配为 moonhttp 的 `ProgressEvent` 回调。
fn adapt_progress(
  on_progress : ((@types.Progress) -> Unit)?,
) -> ((@config.ProgressEvent) -> Unit)? {
  match on_progress {
    Some(report) =>
      Some(fn(event) { report({ loaded: event.loaded, total: event.total, }) })
    None => None
  }
}
