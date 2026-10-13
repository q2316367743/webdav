// 客户端核心：实例构造、URL 拼接、请求发送与状态检查。

///|
/// WebDAV 客户端：全部操作以方法形式挂在本类型上。
/// 通过 `create_webdav_client` 构造（根包重导出）。
pub struct WebdavClient {
  priv http : @moonhttp.Client
  priv base_url : String
  /// 423 自动重试开关（来自 `WebdavConfig.retry_on_423`）
  priv retry_on_423 : Bool
  /// 本客户端加过的锁（进程内、有界），供 423 自动重试找覆盖锁的令牌
  priv mut known_locks : Array[KnownLock]
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
    retry_on_423: config.retry_on_423.unwrap_or(false),
    known_locks: [],
  }
}

///|
/// 拼接请求 URL：规范化后的 base_url + percent 编码后的路径。
fn WebdavClient::url_for(self : WebdavClient, path : String) -> String {
  let normalized = if path.has_prefix("/") { path } else { "/" + path }
  self.base_url + @types.percent_encode_path(normalized)
}

///|
/// 发送文本请求体（或无请求体）的请求并校验状态码。
/// XML 类操作（PROPFIND / PROPPATCH）与轻量探测（OPTIONS / HEAD）走这里。
async fn WebdavClient::send(
  self : WebdavClient,
  operation~ : String,
  http_method~ : @config.Method,
  path~ : String,
  headers? : Array[(String, String)],
  body? : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
  ok~ : Array[Int32],
) -> @moonhttp.Response raise @types.WebdavError {
  let url = self.url_for(path)
  let cfg = build_config(url, http_method, headers, body, conditions, operation)
  let mut response = self.perform(cfg, signal?)
  if response.status == 423 && self.retry_on_423 {
    // 被锁挡住且本客户端自己持有覆盖锁：补上令牌重试一次。
    match self.covering_lock_token(path) {
      Some(token) => {
        let retry_conditions = conditions
          .unwrap_or(@types.Conditions::new())
          .with_lock_token(token)
        let retry_cfg = build_config(
          url,
          http_method,
          headers,
          body,
          Some(retry_conditions),
          operation,
        )
        response = self.perform(retry_cfg, signal?)
      }
      None => ()
    }
  }
  check_status(response, operation~, ok~)
}

///|
/// 组装一次请求的配置（方法 / 头 / 体 / 条件头），供 423 重试时原样重建。
fn build_config(
  url : String,
  http_method : @config.Method,
  headers : Array[(String, String)]?,
  body : String?,
  conditions : @types.Conditions?,
  operation : String,
) -> @config.Config raise @types.WebdavError {
  let mut cfg = @config.Config::new(url).with_method(http_method)
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
  apply_conditions(cfg, conditions, operation~, url~)
}

///|
/// 发一次请求并把 moonhttp 的错误映射成本模块错误。
/// 状态码校验留给调用方（423 自动重试需要先看到响应）。
async fn WebdavClient::perform(
  self : WebdavClient,
  cfg : @config.Config,
  signal? : @moonhttp.AbortSignal,
) -> @moonhttp.Response raise @types.WebdavError {
  self.http.request(cfg, signal?) catch {
    error => raise map_http_error(error, signal_reason(signal))
  }
}

///|
/// 把条件请求对象落到请求头上：`If-Match` / `If-None-Match`，以及锁令牌与
/// 通用条件列表所需的 `If` 头（渲染规则见 if_header.mbt）。
/// 归一化后为空的锁令牌视为未设置；没有任何条件时不动 `cfg`。
fn apply_conditions(
  cfg : @config.Config,
  conditions : @types.Conditions?,
  operation~ : String,
  url~ : String,
) -> @config.Config raise @types.WebdavError {
  match conditions {
    Some(cond) => {
      let mut out = cfg
      match cond.if_match {
        Some(etag) => out = out.with_header("If-Match", etag)
        None => ()
      }
      match cond.if_none_match {
        Some(etag) => out = out.with_header("If-None-Match", etag)
        None => ()
      }
      let if_value = render_if_header(cond, url~, operation~)
      if if_value != "" {
        out = out.with_header("If", if_value)
      }
      out
    }
    None => cfg
  }
}

///|
/// 取消信号给出的原因（未提供原因时为 `None`）。
fn signal_reason(signal : @moonhttp.AbortSignal?) -> String? {
  match signal {
    Some(sig) => sig.reason()
    None => None
  }
}

///|
/// 把 moonhttp 的错误映射成本模块的统一错误：取消单独成一类，
/// 其余归入网络 / HTTP 层。
fn map_http_error(
  error : @moonhttp.HttpError,
  reason : String?,
) -> @types.WebdavError {
  if error.is_cancelled() {
    match reason {
      Some(text) => @types.WebdavError::cancelled(reason=text)
      None => @types.WebdavError::cancelled()
    }
  } else {
    @types.WebdavError::http(error)
  }
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
