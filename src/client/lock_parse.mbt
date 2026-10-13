// LOCK 响应解析：从响应头 / 响应体里定出「服务端确认的那把锁」。
// 与 lock_ops.mbt 的操作流程分开，单独成文件以遵守单文件行数上限（RL-04）。

///|
/// 只有令牌、没有 lockdiscovery 元数据时的兜底锁条目。
fn bare_lock(
  token : String,
  timeout : String?,
  scope : @types.LockScope,
) -> @types.ActiveLock {
  { token, scope, depth: None, owner: None, timeout, lockroot: None, }
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
/// 服务端没回 `lockscope` 时按 `default_scope`（本次请求的作用域）回填。
fn lock_from_response(
  response : @moonhttp.Response,
  fallback~ : String,
  operation~ : String,
  default_scope? : @types.LockScope,
) -> @types.ActiveLock raise @types.WebdavError {
  let mut xml_error : @xml.XmlError? = None
  let locks = @xmlutil.parse_lockdiscovery(response.text(), default_scope?) catch {
    error => {
      xml_error = Some(error)
      []
    }
  }
  let header_token = match response.headers.get("Lock-Token") {
    Some(value) => @types.normalize_lock_token(value)
    None => ""
  }
  let scope = default_scope.unwrap_or(@types.LockScope::Exclusive)
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
        fill_timeout(bare_lock(header_token, None, scope), response)
      } else if fallback != "" {
        fill_timeout(bare_lock(fallback, None, scope), response)
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
