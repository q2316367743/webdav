// PROPFIND 请求体生成。allprop 是固定形状，直接字面量；
// 按名请求（named prop）用 xml 库的 Writer 生成，属性名合法性由其校验。

///|
/// 请求全部活属性的 PROPFIND 请求体（Depth 头由调用方设置）。
pub fn propfind_allprop_body() -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>"
}

///|
/// 只要属性名的 PROPFIND 请求体（RFC 4918 §9.1 的 propname）：
/// 服务端只回属性名、不回值，用于先探查资源上有哪些属性。
pub fn propfind_propname_body() -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:propfind xmlns:D=\"DAV:\"><D:propname/></D:propfind>"
}

///|
/// 按名请求属性的 PROPFIND 请求体：`names` 为属性局部名列表，
/// `ns_uri` 为属性所属命名空间 URI。
/// 名字或 URI 非法（不构成合法 XML 名 / 属性）时 raise `WriterError`。
pub fn propfind_named_body(
  names : Array[String],
  ns_uri~ : String,
) -> String raise @xml.WriterError {
  let writer = @xml.Writer::new()
  writer.start_element("D:propfind", [("xmlns:D", "DAV:"), ("xmlns:X", ns_uri)])
  writer.start_element("D:prop", [])
  for name in names {
    writer.empty_element("X:\{name}", [])
  }
  writer.end_element("D:prop")
  writer.end_element("D:propfind")
  writer.to_string()
}
