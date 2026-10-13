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
/// - `scope`：锁作用域，省略时按独占写锁（`LockScope::Exclusive`）；
///   共享锁传 `LockScope::Shared`，可与别的共享锁共存；
/// - `signal`：取消信号。
///
/// 返回服务端确认的锁：令牌优先取 `Lock-Token` 响应头，其次取响应体的
/// 首个 `activelock`；两者都没有时抛 `Api`。响应体 XML 非法但带
/// `Lock-Token` 头时仍算成功，元数据退化为默认值。成功后这把锁会记进
/// 客户端本地注册表，供写请求被 423 拒绝时自动补令牌重试。
pub async fn WebdavClient::lock(
  self : WebdavClient,
  path~ : String,
  owner? : String,
  timeout? : String,
  depth? : @types.Depth,
  scope? : @types.LockScope,
  signal? : @moonhttp.AbortSignal,
) -> @types.LockResult raise @types.WebdavError {
  check_lock_depth(depth)
  let body = @xmlutil.lockinfo_body(owner?, scope?) catch {
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
  let result : @types.LockResult = {
    status: response.status,
    created: response.status == 201,
    lock: lock_from_response(
      response,
      fallback="",
      operation="LOCK",
      default_scope=scope.unwrap_or(@types.LockScope::Exclusive),
    ),
  }
  // 记账：拿到锁之后，写请求被 423 拒绝才有令牌可自动补；
  // 响应没回 depth 时用请求时声明的 Depth 兜底（祖先锁的覆盖范围靠它）
  let declared_depth = match depth {
    Some(value) => Some(value.to_header())
    None => None
  }
  self.remember_lock(path, result.lock, declared_depth?)
  result
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
  let result : @types.LockResult = {
    status: response.status,
    created: false,
    lock: lock_from_response(response, fallback=normalized, operation="LOCK"),
  }
  // 刷新可能换新令牌（服务端有权这么做），按最新令牌重新记账
  self.remember_lock(path, result.lock)
  result
}

///|
/// 释放锁（UNLOCK，RFC 4918 §9.11）。`Lock-Token` 头按 `<令牌>` 形态发送。
///
/// 200 / 204 表示已释放；409 通常表示令牌与资源上的锁不匹配。
/// 释放成功后这把锁从本地注册表里去掉，之后写请求不会再自动带它。
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
  self.forget_lock(path, normalized)
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
