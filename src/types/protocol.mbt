// 协议相关的公共小类型：Depth 头、条件请求、OPTIONS 能力探测结果、
// 属性级读取结果与部分失败条目。与具体操作实现解耦，单独成文件以遵守
// 单文件行数上限（AGENTS.md RL-04）。

///|
/// `Depth` 头取值（RFC 4918 §10.2）：PROPFIND 的作用深度与 COPY 的
/// 是否浅拷贝都由它表达。
pub(all) enum Depth {
  /// 只作用于目标资源自身
  Zero
  /// 作用于目标资源及其直接子项
  One
  /// 递归作用于整棵子树
  Infinity
}

///|
/// 渲染为 HTTP 头文本：`"0"` / `"1"` / `"infinity"`。
pub fn Depth::to_header(self : Depth) -> String {
  match self {
    Zero => "0"
    One => "1"
    Infinity => "infinity"
  }
}

///|
/// 条件请求：`If-Match` / `If-None-Match`，取值是服务端给出的 ETag
/// （含引号，原样透传）或通配符 `*`。用于乐观并发控制。
pub(all) struct Conditions {
  if_match : String?
  if_none_match : String?
}

///|
/// 按需构造条件：两个字段都可省略，省略即不发送对应请求头。
pub fn Conditions::new(
  if_match? : String,
  if_none_match? : String,
) -> Conditions {
  { if_match, if_none_match, }
}

///|
/// OPTIONS 能力探测结果（`DAV` / `Allow` / `Server` 头）。
pub(all) struct ServerCapabilities {
  /// `DAV` 头解析出的合规等级（1 / 2 / 3）；
  /// 没有该头时按 RFC 4918 §10.1 视为 `[1]`
  dav_class : Array[Int]
  /// `Allow` 头解析出的方法名（ASCII 大写，保持服务端给出的顺序）
  allow : Array[String]
  /// `Server` 头原文
  server : String?
}

///|
/// 服务端是否声明支持某方法（比较 `Allow` 列表，ASCII 大小写不敏感）。
pub fn ServerCapabilities::supports(
  self : ServerCapabilities,
  http_method : String,
) -> Bool {
  let target = ascii_upper(http_method)
  for item in self.allow {
    if ascii_upper(item) == target {
      return true
    }
  }
  false
}

///|
/// 是否具备 Class 2 作品锁能力（`DAV` 等级含 2，或 `Allow` 含 `LOCK`）。
pub fn ServerCapabilities::has_lock(self : ServerCapabilities) -> Bool {
  self.dav_class.contains(2) || self.supports("LOCK")
}

///|
/// 属性级读取结果：`status` 是该属性所在 `propstat` 的状态码，
/// 404 表示「服务端没有这个属性」，与「属性值为空串」区分开。
pub(all) struct PropResult {
  name : String
  value : String
  status : Int
}

///|
/// 部分失败条目：207 Multi-Status 中非 2xx 的那个资源。
pub(all) struct ResourceFailure {
  /// 服务端返回的原始 href
  href : String
  /// 该资源的 HTTP 状态码
  status : Int
  /// 状态码的中文注解
  message : String
}

///|
/// ASCII 大写化：HTTP 方法名与 `DAV` 等级都是 ASCII 文本，够用且不引入依赖。
pub fn ascii_upper(text : String) -> String {
  let buf = StringBuilder()
  for ch in text {
    let code = ch.to_int()
    if code >= 0x61 && code <= 0x7A {
      buf.write_char((code - 0x20).unsafe_to_char())
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
