// 本客户端加过的锁的进程内注册表：为「写请求被 423 拒绝时用自己持有的锁
// 令牌自动重试一次」提供查找依据（RFC 4918 §9.10.5 / §10.4.4）。
// 单独成文件以遵守单文件行数上限（AGENTS.md RL-04）。

///|
/// 注册表里的一条记录：锁令牌 + 规范化路径 + 锁深度。
/// 只有 `depth == Some("infinity")` 的锁才会覆盖其后代路径；
/// `depth` 为 `None`（服务端没回 `depth`）时按「只覆盖自身」处理，宁可
/// 少重试也不越权使用别的资源的令牌。
priv struct KnownLock {
  token : String
  path : String
  depth : String?
}

///|
/// 注册表容量上限：超出后淘汰最旧的一条。
/// 取值只为兜住长期运行的客户端内存，不承担正确性职责
/// （被淘汰的锁只是失去自动重试能力，显式传 `lock_token` 仍然可用）。
const MAX_KNOWN_LOCKS : Int = 256

///|
/// 规范化路径用于覆盖判定：压掉重复与结尾的 `/`，统一成单个前导 `/`
/// 的形态，使 `/demo/a.txt`、`demo/a.txt`、`/demo/a.txt/` 视作同一路径；
/// 空路径仍规范化为空串（表示挂载点本身）。
fn normalize_lock_path(path : String) -> String {
  let buf = StringBuilder()
  for segment in path.split("/") {
    if segment.length() > 0 {
      buf.write_char('/')
      buf.write_view(segment)
    }
  }
  buf.to_string()
}

///|
/// 判断 `ancestor` 是否是 `path` 的祖先（或同一路径），两侧都先规范化。
/// 空路径视为整个挂载点，是所有路径的祖先。
fn is_path_ancestor(ancestor : String, path : String) -> Bool {
  let parent = normalize_lock_path(ancestor)
  let target = normalize_lock_path(path)
  if parent == "" {
    true
  } else {
    target == parent || target.has_prefix(parent + "/")
  }
}

///|
/// 记账一把新拿到的锁（`lock` / `refresh_lock` 成功后调用）。
/// 同一把锁重复记账只保留一条，避免占满容量；超出上限淘汰最旧的一条。
/// `declared_depth` 是请求时声明的 `Depth`：服务端响应里没回 `depth` 时
/// 用它兜底，否则祖先路径上的锁会认不出自己的覆盖范围。
fn WebdavClient::remember_lock(
  self : WebdavClient,
  path : String,
  lock : @types.ActiveLock,
  declared_depth? : String,
) -> Unit {
  let target = normalize_lock_path(path)
  let depth = match lock.depth {
    Some(value) => Some(value)
    None => declared_depth
  }
  for known in self.known_locks {
    if known.token == lock.token && known.path == target {
      return
    }
  }
  if self.known_locks.length() >= MAX_KNOWN_LOCKS {
    let kept : Array[KnownLock] = []
    for i = 1; i < self.known_locks.length(); i = i + 1 {
      kept.push(self.known_locks[i])
    }
    self.known_locks = kept
  }
  self.known_locks.push({ token: lock.token, path: target, depth, })
}

///|
/// 注销一把已经释放的锁（`unlock` 成功后调用）。
fn WebdavClient::forget_lock(
  self : WebdavClient,
  path : String,
  token : String,
) -> Unit {
  let target = normalize_lock_path(path)
  let kept : Array[KnownLock] = []
  for known in self.known_locks {
    if known.token == token && known.path == target {
      continue
    }
    kept.push(known)
  }
  self.known_locks = kept
}

///|
/// 找一把覆盖 `path` 的已知锁令牌：自身路径上的锁，或锁深度为
/// `"infinity"` 的祖先路径上的锁。取最近记账的一把（后进先出），
/// 找不到返回 `None`。
fn WebdavClient::covering_lock_token(
  self : WebdavClient,
  path : String,
) -> String? {
  let target = normalize_lock_path(path)
  for i = self.known_locks.length() - 1; i >= 0; i = i - 1 {
    let known = self.known_locks[i]
    if known.path == target ||
      (known.depth == Some("infinity") && is_path_ancestor(known.path, target)) {
      return Some(known.token)
    }
  }
  None
}
