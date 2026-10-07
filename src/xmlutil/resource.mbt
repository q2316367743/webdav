// 207 解析结果的对外投影：显示名、按名取属性、映射成 `FileInfo`。
// 单独成文件是为了让 multistatus.mbt 只留类型与事件流解析（RL-04 行数上限）。

///|
/// 尝试把属性文本解析为整数，失败（含空串 / 非数字）返回 `None`。
fn parse_prop_int(value : String?) -> Int? {
  match value {
    Some(text) => @types.parse_ascii_int(text)
    None => None
  }
}

///|
/// 取 href 最后一个非空路径段并 percent 解码，作为显示名。
/// 目录 href 常以 `/` 结尾（末段为空），根路径本身得到空串。
pub fn ParsedResource::display_name(self : ParsedResource) -> String {
  let mut last = ""
  for segment in self.href.split("/") {
    if segment != "" {
      let buf = StringBuilder()
      buf.write_view(segment)
      last = buf.to_string()
    }
  }
  @types.percent_decode(last)
}

///|
/// 在属性列表中找指定局部名 + 命名空间的值（取第一个命中）。
/// 只认 2xx 的 propstat：404 / 403 的属性视为「没有这个属性」。
pub fn ParsedResource::find_prop(
  self : ParsedResource,
  local_name~ : String,
  ns_uri~ : String,
) -> String? {
  let mut found : String? = None
  for prop in self.props {
    if prop.name == local_name &&
      prop.ns_uri == Some(ns_uri) &&
      is_success_status(prop.status) &&
      found is None {
      found = Some(prop.value)
    }
  }
  found
}

///|
/// 把解析结果映射为对外的 `FileInfo`（DAV: 活属性逐项提取）。
pub fn ParsedResource::to_file_info(self : ParsedResource) -> @types.FileInfo {
  fn dav(local_name : String) -> String? {
    self.find_prop(local_name~, ns_uri="DAV:")
  }
  {
    href: self.href,
    name: self.display_name(),
    is_dir: self.is_dir,
    content_length: parse_prop_int(dav("getcontentlength")),
    content_type: dav("getcontenttype"),
    last_modified: dav("getlastmodified"),
    created: dav("creationdate"),
    etag: dav("getetag"),
  }
}
