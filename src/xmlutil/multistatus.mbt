// 207 Multi-Status 响应解析：NamespaceReader 事件流 + local_name 栈。
// 匹配一律看 local_name + namespace_uri（DAV:），不依赖服务端前缀写法；
// 解析策略宽松：不校验 propstat 状态行、无法识别的结构直接跳过。

///|
/// PROPFIND 响应中一个 `<D:response>` 的解析结果。
pub(all) struct ParsedResource {
  /// 服务端原始 href（URL 编码，未解码）
  href : String
  /// 是否目录（resourcetype 含 collection）
  is_dir : Bool
  /// prop 下收集到的全部属性（DAV: 活属性与自定义死属性混排）
  props : Array[ParsedProp]
}

///|
/// 一个属性的局部名、命名空间 URI 与文本值。
pub(all) struct ParsedProp {
  name : String
  ns_uri : String?
  value : String
}

///|
/// 解析过程的中间累积器；`href` / `is_dir` 随事件填充。
priv struct ResBuilder {
  mut href : String
  mut is_dir : Bool
  props : Array[ParsedProp]
}

///|
fn ResBuilder::new() -> ResBuilder {
  { href: "", is_dir: false, props: [], }
}

///|
/// 按 local_name + 命名空间匹配 DAV: 元素名。
fn is_dav_name(name : @xml.XmlName, local_name : String) -> Bool {
  name.local_name == local_name && name.namespace_uri == Some("DAV:")
}

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
pub fn ParsedResource::find_prop(
  self : ParsedResource,
  local_name~ : String,
  ns_uri~ : String,
) -> String? {
  let mut found : String? = None
  for prop in self.props {
    if prop.name == local_name && prop.ns_uri == Some(ns_uri) && found is None {
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

///|
/// 解析 207 Multi-Status 响应体，返回全部 `<D:response>` 条目。
pub fn parse_multistatus(
  xml_text : String,
) -> Array[ParsedResource] raise @xml.XmlError {
  let reader = @xml.NamespaceReader::from_string(xml_text)
  let resources : Array[ParsedResource] = []
  // 打开元素的 local_name 栈：multistatus=1，response=2，其下递增
  let stack : Array[String] = []
  let mut builder : ResBuilder? = None
  let mut href_buf : StringBuilder? = None
  // prop 下正在累积文本的叶子：(局部名, 命名空间, 文本缓冲)
  let mut pending : (String, String?, StringBuilder)? = None
  fn mark_collection() -> Unit {
    match builder {
      Some(b) => b.is_dir = true
      None => ()
    }
  }
  fn push_prop(prop : ParsedProp) -> Unit {
    match builder {
      Some(b) => b.props.push(prop)
      None => ()
    }
  }
  while true {
    let event = reader.read_event()
    match event.kind {
      Eof => break
      Start(el) => {
        let name = el.name
        stack.push(name.local_name)
        let depth = stack.length()
        let parent = if depth >= 2 { Some(stack[depth - 2]) } else { None }
        if is_dav_name(name, "response") && depth == 2 {
          builder = Some(ResBuilder::new())
        } else if is_dav_name(name, "collection") &&
          parent == Some("resourcetype") {
          mark_collection()
        } else if is_dav_name(name, "href") &&
          depth == 3 &&
          parent == Some("response") {
          href_buf = Some(StringBuilder())
        } else if parent == Some("prop") &&
          name.local_name != "resourcetype" &&
          pending is None {
          pending = Some((name.local_name, name.namespace_uri, StringBuilder()))
        }
      }
      Empty(el) => {
        // 自闭合元素：等价于 Start + End，叶子值记空串
        let name = el.name
        stack.push(name.local_name)
        let depth = stack.length()
        let parent = if depth >= 2 { Some(stack[depth - 2]) } else { None }
        if is_dav_name(name, "collection") && parent == Some("resourcetype") {
          mark_collection()
        } else if parent == Some("prop") && name.local_name != "resourcetype" {
          push_prop({
            name: name.local_name,
            ns_uri: name.namespace_uri,
            value: "",
          })
        }
        ignore(stack.pop())
      }
      Text(text) =>
        match pending {
          Some((_, _, buf)) => buf.write_string(text)
          None =>
            match href_buf {
              Some(buf) => buf.write_string(text)
              None => ()
            }
        }
      CData(text) =>
        match pending {
          Some((_, _, buf)) => buf.write_string(text)
          None =>
            match href_buf {
              Some(buf) => buf.write_string(text)
              None => ()
            }
        }
      End(name) => {
        if is_dav_name(name, "href") {
          match (builder, href_buf) {
            (Some(b), Some(buf)) => b.href = buf.to_string()
            _ => ()
          }
          href_buf = None
        }
        match pending {
          Some((pending_name, ns_uri, buf)) =>
            if name.local_name == pending_name {
              push_prop({ name: pending_name, ns_uri, value: buf.to_string(), })
              pending = None
            }
          None => ()
        }
        if is_dav_name(name, "response") {
          match builder {
            Some(b) => {
              resources.push({ href: b.href, is_dir: b.is_dir, props: b.props, })
              builder = None
            }
            None => ()
          }
        }
        ignore(stack.pop())
      }
      _ => ()
    }
  }
  resources
}
