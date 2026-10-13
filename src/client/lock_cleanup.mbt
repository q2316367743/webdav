// lock-null 资源的清理（RFC 4918 §7.3）。
//
// 一次「锁定还不存在的路径」的 LOCK 会让服务端创建空资源，而 RFC 明确
// 这个资源在锁消失后**不会**自动消失、清理责任在客户端：
// "A resource created with a LOCK is empty but otherwise behaves in every
// way as a normal resource. ... SHOULD NOT disappear when its lock goes
// away (clients must therefore be responsible for cleaning up their own
// mess.)"。这里只在能证明「它仍是那个空资源」时才动手删。
// 单独成文件以遵守单文件行数上限（AGENTS.md RL-04）。

///|
/// HEAD 探测结果：资源是否还在、长度（`None` = 未知，按非空处理）、ETag。
priv struct NullProbe {
  missing : Bool
  length : Int?
  etag : String?
}

///|
/// 释放锁并清掉因这次锁而创建的空资源（lock-null，RFC 4918 §7.3）。
///
/// 顺序与判定：
/// 1. `unlock`：404 / 409 说明锁已经不在了（已过期或已被释放），继续收尾；
///    其他错误照抛，交给调用方决定；
/// 2. 探测资源：**只删「仍存在且长度恰为 0」**的；长度未知（服务端没给
///    `Content-Length`，或不支持 HEAD）一律不碰，宁可留垃圾也不误删内容；
/// 3. 删除时带上探测到的 ETag（`If-Match`），避免误删并发写入的新内容。
///
/// 返回 `true` 表示确实删掉了这个空资源，`false` 表示没删。
pub async fn WebdavClient::cleanup_lock_null(
  self : WebdavClient,
  path~ : String,
  token~ : String,
  signal? : @moonhttp.AbortSignal,
) -> Bool raise @types.WebdavError {
  let released : Result[Unit, @types.WebdavError] = try {
    self.unlock(path~, token~, signal?)
    Ok(())
  } catch {
    error => Err(error)
  }
  match released {
    Ok(_) => ()
    Err(error) =>
      match error.detail() {
        // 锁已经不在：继续收拾可能残留的空资源
        Api(status=404, operation=_, message=_) => ()
        Api(status=409, operation=_, message=_) => ()
        _ => raise error
      }
  }
  let probe = self.probe_null(path~, signal?)
  if probe.missing {
    return false
  }
  if probe.length != Some(0) {
    return false
  }
  let conditions = match probe.etag {
    Some(etag) => @types.Conditions::new(if_match=etag)
    None => @types.Conditions::new()
  }
  self.delete(path~, conditions~, signal?)
  true
}

///|
/// 探测 lock-null 残留资源：HEAD 拿长度与 ETag，404 视为已不在；
/// 服务端不支持 HEAD（405 / 501）时退回 PROPFIND 只判存在性，
/// 长度按未知（不删）处理。
async fn WebdavClient::probe_null(
  self : WebdavClient,
  path~ : String,
  signal? : @moonhttp.AbortSignal,
) -> NullProbe raise @types.WebdavError {
  let response = self.send(
    operation="HEAD",
    http_method=@config.Method::Head,
    path~,
    signal?,
    ok=[200, 204, 304, 404, 405, 501],
  )
  let status = response.status
  if status == 404 {
    return { missing: true, length: None, etag: None, }
  }
  if status == 405 || status == 501 {
    let exists = self.exists_by_propfind(path~, signal?)
    return { missing: !exists, length: None, etag: None, }
  }
  let length = match response.headers.get("Content-Length") {
    Some(value) => @types.parse_ascii_int(value.trim().to_owned())
    None => None
  }
  { missing: false, length, etag: response.headers.get("ETag"), }
}
