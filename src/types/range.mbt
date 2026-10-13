// HTTP Range 区间下载（RFC 7233）的公共类型：请求侧的 `ByteRange`
// 与响应侧的 `Content-Range` 解析。断点续传（client 包）建立在两者之上。

///|
/// HTTP 字节区间（RFC 7233）：字节从 0 计，`end` 为**含端**。
/// 只能经 `ByteRange::from` / `ByteRange::suffix` 构造，保证取值合法：
/// 后缀形式（取资源末尾 N 字节）以负数 `start = -N` 存储。
pub struct ByteRange {
  /// 起始字节；后缀形式时为负数 `-N`（`N` 为要取的末尾字节数）
  start : Int32
  /// 结束字节（含）；`None` 表示一直到资源末尾（`bytes=N-`）
  end : Int32?
}

///|
/// 区间下载：`start` 缺省 0；`end` 省略表示到资源末尾（`bytes=start-`），
/// 提供则是闭区间（`bytes=start-end`，两端都含）。
pub fn ByteRange::from(start? : Int32, end? : Int32) -> ByteRange {
  { start: start.unwrap_or(0), end, }
}

///|
/// 后缀区间：取资源**末尾** `length` 个字节（`bytes=-length`），
/// `length` 应为正数。
pub fn ByteRange::suffix(length : Int32) -> ByteRange {
  { start: -length, end: None, }
}

///|
/// 渲染成 `Range` 请求头的值：`bytes=start-end` / `bytes=start-` /
/// `bytes=-length`（后缀形式）。
pub fn ByteRange::header_value(self : ByteRange) -> String {
  let start = self.start
  if start < 0 {
    "bytes=\{start}"
  } else {
    match self.end {
      Some(end) => "bytes=\{start}-\{end}"
      None => "bytes=\{start}-"
    }
  }
}

///|
/// 206（部分内容）响应 `Content-Range` 头的解析结果：
/// `bytes first-last/total`，描述服务器实际返回的区间。
pub(all) struct ContentRange {
  /// 区间起始字节（含）
  first : Int32
  /// 区间结束字节（含）
  last : Int32
  /// 资源总字节数；服务器未知时（`bytes a-b/*`）为 `None`
  total : Int32?
}

///|
/// 解析 206 响应的 `Content-Range` 头。RFC 写法为 `bytes 0-1/2`（空格），
/// 部分实现写 `bytes=0-1/2`（等号），均容忍；形态不符 / 数字非法
/// 返回 `None`（`bytes */total` 形态属于 416 响应，用
/// `parse_unsatisfied_range_total` 解析）。
pub fn parse_content_range(text : String) -> ContentRange? {
  let body = strip_range_unit(text.trim().to_owned())
  match body.find("/") {
    Some(slash) => {
      let range_part = body[:slash].to_owned()
      let total_text = body[slash + 1:].to_owned()
      match range_part.find("-") {
        Some(dash) =>
          match
            (
              parse_ascii_int(range_part[:dash].to_owned().trim().to_owned()),
              parse_ascii_int(
                range_part[dash + 1:].to_owned().trim().to_owned(),
              ),
            ) {
            (Some(first), Some(last)) =>
              match parse_range_total(total_text) {
                Some(total) => Some({ first, last, total, })
                None => None
              }
            _ => None
          }
        None => None
      }
    }
    None => None
  }
}

///|
/// 解析 416 响应的 `Content-Range: bytes */total`（服务器告知资源总长）。
/// 形态不符时返回 `None`。
pub fn parse_unsatisfied_range_total(text : String) -> Int32? {
  let body = strip_range_unit(text.trim().to_owned())
  match body.find("/") {
    Some(slash) => {
      let left = body[:slash].to_owned().trim()
      let total = parse_ascii_int(body[slash + 1:].to_owned().trim().to_owned())
      if left == "*" {
        total
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// 去掉 `Content-Range` 的单位前缀：`bytes=…` 与 `bytes …` 两种写法
/// 均剥成 `…`；无前缀原样返回。
fn strip_range_unit(text : String) -> String {
  if text.has_prefix("bytes") {
    let rest = text[5:].to_owned()
    if rest.has_prefix("=") || rest.has_prefix(" ") {
      rest[1:].to_owned()
    } else {
      rest
    }
  } else {
    text
  }
}

///|
/// 解析 `Content-Range` 的总长段：`*` 视为「服务器未知」（成功，
/// 结果为 `None`），纯数字为已知总长，其余非法（返回 `None`）。
fn parse_range_total(text : String) -> Int32?? {
  let trimmed = text.trim().to_owned()
  if trimmed == "*" {
    Some(None)
  } else {
    match parse_ascii_int(trimmed) {
      Some(total) => Some(Some(total))
      None => None
    }
  }
}
