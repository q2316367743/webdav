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
