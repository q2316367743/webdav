// 路径的 percent 编码 / 解码。
// WebDAV 路径里允许任意 Unicode 与保留字符：发请求前逐段编码（`/` 保留），
// 解析 PROPFIND 返回的 href 时解码还原显示名。
// 逐字节操作时 `Bytes[i]` / `String[i]` 返回 `Byte` / `UInt16`，
// 本文件统一在 Int 域上比较，再按需转换。

///|
/// unreserved = ALPHA / DIGIT / `-` / `.` / `_` / `~`（RFC 3986 §2.3）。
fn is_unreserved(byte : Int) -> Bool {
  (byte >= 0x41 && byte <= 0x5A) ||
  (byte >= 0x61 && byte <= 0x7A) ||
  (byte >= 0x30 && byte <= 0x39) ||
  byte == 0x2D ||
  byte == 0x2E ||
  byte == 0x5F ||
  byte == 0x7E
}

///|
/// `0 ~ 15` 的十六进制字符；调用方保证值域，故直接取 ASCII 码。
fn hex_char(value : Int) -> Char {
  if value < 10 {
    (0x30 + value).unsafe_to_char()
  } else {
    (0x37 + value).unsafe_to_char()
  }
}

///|
/// 单个十六进制字节的数值；非十六进制返回 `None`。
fn hex_value(code : Byte) -> Int? {
  let c = code.to_int()
  if c >= 0x30 && c <= 0x39 {
    Some(c - 0x30)
  } else if c >= 0x41 && c <= 0x46 {
    Some(c - 0x41 + 10)
  } else if c >= 0x61 && c <= 0x66 {
    Some(c - 0x61 + 10)
  } else {
    None
  }
}

///|
/// 解析纯 ASCII 数字文本（如 Content-Length、getcontentlength）。
/// 空串、含非数字字符时返回 `None`。
pub fn parse_ascii_int(text : String) -> Int? {
  if text == "" {
    None
  } else {
    let mut number = 0
    let mut ok = true
    for ch in text {
      let digit = ch.to_int() - 0x30
      if digit >= 0 && digit <= 9 {
        number = number * 10 + digit
      } else {
        ok = false
        break
      }
    }
    if ok {
      Some(number)
    } else {
      None
    }
  }
}

///|
/// 把路径按 RFC 3986 做 percent 编码：保留 `/` 与 unreserved 字符，
/// 其余（空格、中文、`?`、`#` 等保留 / 分隔字符）逐 UTF-8 字节编码为 `%XX`。
/// 注意空格编码为 `%20` 而非表单的 `+`。
pub fn percent_encode_path(path : String) -> String {
  let buf = StringBuilder()
  let bytes = @utf8.encode(path)
  let len = bytes.length()
  let mut i = 0
  while i < len {
    let byte = bytes[i].to_int()
    if byte == 0x2F || is_unreserved(byte) {
      // 走到这里的一定是 ASCII（unreserved 与 `/`），unsafe_to_char 安全
      buf.write_char(byte.unsafe_to_char())
    } else {
      buf.write_char('%')
      buf.write_char(hex_char(byte / 16))
      buf.write_char(hex_char(byte % 16))
    }
    i = i + 1
  }
  buf.to_string()
}

///|
/// 解码 percent 编码的字符串（如 PROPFIND 返回的 href）。
/// 非法转义序列原样保留；解码结果按 UTF-8 还原，失败时保守返回原文。
pub fn percent_decode(text : String) -> String {
  let bytes = @utf8.encode(text)
  let len = bytes.length()
  let out = @buffer.Buffer::Buffer()
  let mut decoded_any = false
  let mut i = 0
  while i < len {
    let byte = bytes[i].to_int()
    if byte == 0x25 && i + 2 < len {
      match (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
        (Some(hi), Some(lo)) => {
          out.write_byte((hi * 16 + lo).to_byte())
          decoded_any = true
          i = i + 3
          continue
        }
        _ => ()
      }
    }
    out.write_byte(bytes[i])
    i = i + 1
  }
  if decoded_any {
    @utf8.decode(out.to_bytes()) catch {
      _ => text // 解码出非 UTF-8 序列，保守返回原文
    }
  } else {
    text
  }
}

///|
/// 把 207 响应里的 href 归一化成服务器上的绝对路径，供「与服务端路径比对」
/// 与「用作本地路径」两种用途：
///
/// - 剥离 `scheme://authority`（部分服务端与反向代理会回绝对 URL）；
/// - 丢弃 `?query` 与 `#fragment`；
/// - percent 解码；
/// - 去掉末尾斜杠（根路径 `/` 保留）。
pub fn href_to_path(href : String) -> String {
  let path = match href.find("://") {
    Some(scheme_end) => {
      let rest = href[scheme_end + 3:].to_owned()
      match rest.find("/") {
        Some(slash) => rest[slash:].to_owned()
        None => "/"
      }
    }
    None => href
  }
  trim_trailing_slash(percent_decode(strip_query_fragment(path)))
}

///|
/// 砍掉 `?query` 与 `#fragment`：两者之后的内容不属于路径。
fn strip_query_fragment(text : String) -> String {
  let buf = StringBuilder()
  for ch in text {
    if ch == '?' || ch == '#' {
      break
    }
    buf.write_char(ch)
  }
  buf.to_string()
}

///|
/// 去掉末尾斜杠；根路径 `/` 与空串保持不变。
fn trim_trailing_slash(text : String) -> String {
  if text.has_suffix("/") && text.length() > 1 {
    text[:text.length() - 1].to_owned()
  } else {
    text
  }
}
