// 锁操作：LOCK（申请 / 刷新）、UNLOCK、锁发现（PROPFIND lockdiscovery）。
// 请求体生成与 lockdiscovery 解析见 xmlutil/lockinfo.mbt；
// 锁令牌落到 `If` / `Lock-Token` 请求头见 client.mbt。

///|
/// 申请独占写锁（LOCK，RFC 4918 §9.10）。
///
/// - `path`：要锁定的资源路径；
/// - `owner`：持有者标识，写进请求体 `<D:owner>` 的文本，省略则不写该元素；
/// - `timeout`：`Timeout` 头原文，如 `"Second-300"` / `"Infinite"`，
///   省略则用服务端默认值；
/// - `depth`：只支持 `Depth::Zero` 与 `Depth::Infinity`；`Depth::One`
///   对 LOCK 非法，发请求前抛 `Api` 400。省略时不发 `Depth` 头；
/// - `signal`：取消信号。
///
/// 返回服务端确认的锁：令牌优先取 `Lock-Token` 响应头，其次取响应体的
/// 首个 `activelock`；两者都没有时抛 `Api`。响应体 XML 非法但带
/// `Lock-Token` 头时仍算成功，元数据退化为默认值。
pub async fn WebdavClient::lock(
  self : WebdavClient,
  path~ : String,
  owner? : String,
  timeout? : String,
  depth? : @types.Depth,
  signal? : @moonhttp.AbortSignal,
) -> @types.LockResult raise @types.WebdavError {
  check_lock_depth(depth)
  let body = @xmlutil.lockinfo_body(owner?) catch {
    error => raise invalid_request_body(error, operation="LOCK")
  }
  let headers : Array[(String, String)] = [
    ("Content-Type", "application/xml; charset=utf-8"),
  ]
  match timeout {
    Some(value) => headers.push(("Timeout", value))
    None => ()
  }
  match depth {
    Some(value) => headers.push(("Depth", value.to_header()))
    None => ()
  }
  let response = self.send(
    operation="LOCK",
    http_method=@config.Method::Other("LOCK"),
    path~,
    headers~,
    body~,
    signal?,
    ok=[200, 201],
  )
  {
    status: response.status,
    created: response.status == 201,
    lock: lock_from_response(response, fallback="", operation="LOCK"),
  }
}

///|
/// 刷新锁（LOCK 无请求体 + `If` 头，RFC 4918 §9.10.2）。
///
/// 刷新不换令牌：响应里没有令牌时沿用传入的 `token`。
/// `timeout` 与 `signal` 含义同 `lock`；`Depth` 不参与刷新，一律不发。
pub async fn WebdavClient::refresh_lock(
  self : WebdavClient,
  path~ : String,
  token~ : String,
  timeout? : String,
  signal? : @moonhttp.AbortSignal,
) -> @types.LockResult raise @types.WebdavError {
  let normalized = require_lock_token(token, operation="LOCK")
  let headers : Array[(String, String)] = [
    ("If", lock_token_if_value(normalized)),
  ]
  match timeout {
    Some(value) => headers.push(("Timeout", value))
    None => ()
  }
  let response = self.send(
    operation="LOCK",
    http_method=@config.Method::Other("LOCK"),
    path~,
    headers~,
    signal?,
    ok=[200],
  )
  {
    status: response.status,
    created: false,
    lock: lock_from_response(response, fallback=normalized, operation="LOCK"),
  }
}

///|
/// 释放锁（UNLOCK，RFC 4918 §9.11）。`Lock-Token` 头按 `<令牌>` 形态发送。
///
/// 200 / 204 表示已释放；409 通常表示令牌与资源上的锁不匹配。
pub async fn WebdavClient::unlock(
  self : WebdavClient,
  path~ : String,
  token~ : String,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let normalized = require_lock_token(token, operation="UNLOCK")
  ignore(
    self.send(
      operation="UNLOCK",
      http_method=@config.Method::Other("UNLOCK"),
      path~,
      headers=[("Lock-Token", lock_token_uri(normalized))],
      signal?,
      ok=[200, 204],
    ),
  )
}

///|
/// 读资源上的活动锁（PROPFIND `lockdiscovery`，Depth 0）。
///
/// 返回活动锁列表；没有锁时是空数组。部分服务端（如 hacdias/webdav）
/// 不回 `lockdiscovery` 的值，此时同样得到空数组。
pub async fn WebdavClient::get_locks(
  self : WebdavClient,
  path~ : String,
  signal? : @moonhttp.AbortSignal,
) -> Array[@types.ActiveLock] raise @types.WebdavError {
  let body = @xmlutil.propfind_named_body(["lockdiscovery"], ns_uri="DAV:") catch {
    error => raise invalid_request_body(error, operation="PROPFIND")
  }
  let response = self.send(
    operation="PROPFIND",
    http_method=@config.Method::Other("PROPFIND"),
    path~,
    headers=[("Depth", "0"), ("Content-Type", "application/xml; charset=utf-8")],
    body~,
    signal?,
    ok=[207],
  )
  @xmlutil.parse_lockdiscovery(response.text()) catch {
    error => raise @types.WebdavError::xml(error)
  }
}

///|
/// LOCK 的 `Depth` 只允许 0 与 infinity（RFC 4918 §9.10.3）。
fn check_lock_depth(depth : @types.Depth?) -> Unit raise @types.WebdavError {
  match depth {
    Some(@types.Depth::One) =>
      raise @types.WebdavError::api(
        status=400,
        operation="LOCK",
        message="LOCK 的 Depth 只能是 0 或 infinity",
      )
    _ => ()
  }
}

///|
/// 校验并归一化锁令牌：空令牌在发请求前就拦掉，避免发出 `If: ()` /
/// `Lock-Token: <>` 这种必然被服务端拒绝的请求。
fn require_lock_token(
  token : String,
  operation~ : String,
) -> String raise @types.WebdavError {
  let normalized = @types.normalize_lock_token(token)
  if normalized == "" {
    raise @types.WebdavError::api(
      status=400,
      operation~,
      message="锁令牌不能为空",
    )
  }
  normalized
}

///|
/// 只有令牌、没有 lockdiscovery 元数据时的兜底锁条目。
fn bare_lock(token : String, timeout : String?) -> @types.ActiveLock {
  {
    token,
    scope: "exclusive",
    depth: None,
    owner: None,
    timeout,
    lockroot: None,
  }
}

///|
/// 用 `Timeout` 响应头补齐响应体缺失的锁超时。
fn fill_timeout(
  lock : @types.ActiveLock,
  response : @moonhttp.Response,
) -> @types.ActiveLock {
  match lock.timeout {
    Some(_) => lock
    None =>
      {
        token: lock.token,
        scope: lock.scope,
        depth: lock.depth,
        owner: lock.owner,
        timeout: first_timeout_segment(response),
        lockroot: lock.lockroot,
      }
  }
}

///|
/// 取 `Timeout` 响应头的首段（形如 `Second-600, Infinite`）；
/// 没有该头或首段为空时返回 `None`。
fn first_timeout_segment(response : @moonhttp.Response) -> String? {
  match response.headers.get("Timeout") {
    Some(value) => {
      let buf = StringBuilder()
      for ch in value {
        if ch == ',' {
          break
        }
        buf.write_char(ch)
      }
      let segment = buf.to_string().trim().to_owned()
      if segment == "" {
        None
      } else {
        Some(segment)
      }
    }
    None => None
  }
}

///|
/// 从 LOCK 响应里取锁：`Lock-Token` 头优先，其次响应体首个 `activelock`；
/// 两者都没有时用 `fallback`（刷新锁用请求里的令牌），`fallback` 为空则抛错。
fn lock_from_response(
  response : @moonhttp.Response,
  fallback~ : String,
  operation~ : String,
) -> @types.ActiveLock raise @types.WebdavError {
  let mut xml_error : @xml.XmlError? = None
  let locks = @xmlutil.parse_lockdiscovery(response.text()) catch {
    error => {
      xml_error = Some(error)
      []
    }
  }
  let header_token = match response.headers.get("Lock-Token") {
    Some(value) => @types.normalize_lock_token(value)
    None => ""
  }
  let from_body = if locks.length() > 0 { Some(locks[0]) } else { None }
  match from_body {
    Some(lock) => {
      // 头与体不一致时以头为准（响应头是权威来源）
      let merged : @types.ActiveLock = if header_token != "" &&
        header_token != lock.token {
        {
          token: header_token,
          scope: lock.scope,
          depth: lock.depth,
          owner: lock.owner,
          timeout: lock.timeout,
          lockroot: lock.lockroot,
        }
      } else {
        lock
      }
      fill_timeout(merged, response)
    }
    None =>
      if header_token != "" {
        fill_timeout(bare_lock(header_token, None), response)
      } else if fallback != "" {
        fill_timeout(bare_lock(fallback, None), response)
      } else {
        match xml_error {
          Some(error) => raise @types.WebdavError::xml(error)
          None =>
            raise @types.WebdavError::api(
              status=response.status,
              operation~,
              message="响应缺少锁令牌（既无 Lock-Token 头也无 lockdiscovery）",
            )
        }
      }
  }
}
