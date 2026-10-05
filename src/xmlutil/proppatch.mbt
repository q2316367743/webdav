// PROPPATCH（propertyupdate）请求体生成：一次写入（set）一组死属性。

///|
/// 生成 PROPPATCH 请求体，`props` 为 (属性局部名, 值) 列表，
/// `ns_uri` 为属性所属命名空间 URI。
/// 属性名非法（不构成合法 XML 名）时 raise `WriterError`。
pub fn proppatch_set_body(
  props : Array[(String, String)],
  ns_uri~ : String,
) -> String raise @xml.WriterError {
  let writer = @xml.Writer::new()
  writer.start_element("D:propertyupdate", [
    ("xmlns:D", "DAV:"),
    ("xmlns:X", ns_uri),
  ])
  writer.start_element("D:set", [])
  writer.start_element("D:prop", [])
  for entry in props {
    let (name, value) = entry
    writer.start_element("X:\{name}", [])
    writer.text(value)
    writer.end_element("X:\{name}")
  }
  writer.end_element("D:prop")
  writer.end_element("D:set")
  writer.end_element("D:propertyupdate")
  writer.to_string()
}
