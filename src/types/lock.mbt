// 锁相关的公共类型：令牌归一化、活动锁条目、LOCK / 刷新锁的响应结果。
// 与具体操作实现解耦，单独成文件以遵守单文件行数上限（AGENTS.md RL-04）。

///|
/// 归一化锁令牌：去掉两侧空白与可选的外层 `<>`。
///
/// 令牌在协议里是不透明串（RFC 4918 §6.4）：常见形式是
/// `opaquelocktoken:...`，但服务端也可能回裸串（hacdias/webdav 就回
/// 裸数字），所以这里不校验 URI 形式，只统一形状。
/// `Lock-Token` 响应头自带尖括号，请求里传入的则通常不带，
/// 两种输入经这里归一后都变成不带尖括号的裸令牌。
pub fn normalize_lock_token(token : String) -> String {
  let trimmed = token.trim().to_owned()
  if trimmed.length() >= 2 && trimmed.has_prefix("<") && trimmed.has_suffix(">") {
    trimmed[1:trimmed.length() - 1].trim().to_owned()
  } else {
    trimmed
  }
}

///|
/// 一条活动锁（RFC 4918 §14.11 `activelock`）。
pub(all) struct ActiveLock {
  /// 归一化后的锁令牌（已去掉外层 `<>`）
  token : String
  /// 锁作用域：`"exclusive"` / `"shared"`；服务端没给 lockscope 时按独占处理
  scope : String
  /// 锁深度：`"0"` / `"infinity"`
  depth : String?
  /// `owner` 元素的文本内容（嵌套 href 的文本也算在内）；
  /// 服务端回了空的 `<D:owner></D:owner>` 时为 `None`
  owner : String?
  /// 锁超时原文：`"Second-3600"` / `"Infinite"`
  timeout : String?
  /// `lockroot` 的 href 原文（可能是相对路径，不做归一）
  lockroot : String?
}

///|
/// LOCK（申请或刷新）的响应结果。
pub(all) struct LockResult {
  /// HTTP 状态码：200 表示锁施加在既有资源上，201 表示服务端借这次锁
  /// 创建了空资源（lock-null）
  status : Int
  /// 是否 201（lock-null 资源被创建）
  created : Bool
  /// 服务端确认的锁
  lock : ActiveLock
}
