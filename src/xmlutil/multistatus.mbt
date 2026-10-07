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
  /// `response` 级 `<D:status>`：批量操作（COPY / MOVE / DELETE）的 207
  /// 用它逐资源给出结果；PROPFIND 风格响应没有该元素时为 `None`
  status : Int?
  /// `response` 级 `<D:responsedescription>` 文本
  responsedescription : String?
}

///|
/// 一个属性的局部名、命名空间 URI 与文本值。
pub(all) struct ParsedProp {
  name : String
  ns_uri : String?
  value : String
  /// 所在 `propstat` 的状态码：404 表示服务端没有这个属性，
  /// 用于把「属性不存在」与「属性值为空」区分开；缺 `<D:status>` 行时按 200
  status : Int
}

///|
/// 解析过程的中间累积器；`href` / `is_dir` 随事件填充。
/// 属性先收在 `pending_props`，等所在 `propstat` 结束、状态码已知后再
/// 逐条打上状态收进 `props`（`<D:status>` 在 `<D:prop>` 之后是常见排布）。
priv struct ResBuilder {
  mut href : String
  mut is_dir : Bool
  mut status : Int?
  mut responsedescription : String?
  props : Array[ParsedProp]
  mut pending_props : Array[ParsedProp]
  mut propstat_status : Int
}

///|
fn ResBuilder::new() -> ResBuilder {
  {
    href: "",
    is_dir: false,
    status: None,
    responsedescription: None,
    props: [],
    pending_props: [],
    propstat_status: 200,
  }
}

///|
/// 从 `<D:status>` 文本（如 `HTTP/1.1 404 Not Found`）里取首个三位数字状态码。
fn parse_http_status(text : String) -> Int? {
  let mut run = 0
  let mut value = 0
  for ch in text {
    let digit = ch.to_int() - 0x30
    if digit >= 0 && digit <= 9 {
      run = run + 1
      value = value * 10 + digit
      if run == 3 {
        return Some(value)
      }
    } else {
      run = 0
      value = 0
    }
  }
  None
}

///|
/// 2xx 视为该属性读到了值。
fn is_success_status(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// 按 local_name + 命名空间匹配 DAV: 元素名。
fn is_dav_name(name : @xml.XmlName, local_name : String) -> Bool {
  name.local_name == local_name && name.namespace_uri == Some("DAV:")
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
  // 正在累积的 <D:status> 文本；status_at_response 区分它是 response 级
  // 还是 propstat 级
  let mut status_buf : StringBuilder? = None
  let mut status_at_response = false
  // 正在累积的 <D:responsedescription> 文本
  let mut desc_buf : StringBuilder? = None
  fn mark_collection() -> Unit {
    match builder {
      Some(b) => b.is_dir = true
      None => ()
    }
  }
  fn push_prop(prop : ParsedProp) -> Unit {
    match builder {
      Some(b) => b.pending_props.push(prop)
      None => ()
    }
  }
  // propstat 结束：这一段属性打上状态码后收进最终列表
  fn flush_propstat() -> Unit {
    match builder {
      Some(b) => {
        for prop in b.pending_props {
          b.props.push({
            name: prop.name,
            ns_uri: prop.ns_uri,
            value: prop.value,
            status: b.propstat_status,
          })
        }
        b.pending_props = []
        b.propstat_status = 200
      }
      None => ()
    }
  }
  // response 结束：兜底 flush 后收条
  fn finish_response() -> Unit {
    match builder {
      Some(b) => {
        flush_propstat()
        resources.push({
          href: b.href,
          is_dir: b.is_dir,
          props: b.props,
          status: b.status,
          responsedescription: b.responsedescription,
        })
        builder = None
      }
      None => ()
    }
  }
  // 文本归属：属性值 > href > status > responsedescription
  fn write_text(text : String) -> Unit {
    if pending is Some((_, _, buf)) {
      buf.write_string(text)
    } else if href_buf is Some(buf) {
      buf.write_string(text)
    } else if status_buf is Some(buf) {
      buf.write_string(text)
    } else if desc_buf is Some(buf) {
      buf.write_string(text)
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
        } else if is_dav_name(name, "propstat") && parent == Some("response") {
          match builder {
            Some(b) => {
              b.propstat_status = 200
              b.pending_props = []
            }
            None => ()
          }
        } else if is_dav_name(name, "status") &&
          (parent == Some("propstat") || parent == Some("response")) {
          status_at_response = parent == Some("response")
          status_buf = Some(StringBuilder())
        } else if is_dav_name(name, "responsedescription") &&
          parent == Some("response") {
          desc_buf = Some(StringBuilder())
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
            status: 200,
          })
        }
        ignore(stack.pop())
      }
      Text(text) => write_text(text)
      CData(text) => write_text(text)
      End(name) => {
        if is_dav_name(name, "href") {
          match (builder, href_buf) {
            (Some(b), Some(buf)) => b.href = buf.to_string()
            _ => ()
          }
          href_buf = None
        }
        if is_dav_name(name, "status") && status_buf is Some(buf) {
          let parsed = parse_http_status(buf.to_string())
          match builder {
            Some(b) =>
              if status_at_response {
                b.status = parsed
              } else {
                b.propstat_status = parsed.unwrap_or(200)
              }
            None => ()
          }
          status_buf = None
        }
        if is_dav_name(name, "responsedescription") && desc_buf is Some(buf) {
          match builder {
            Some(b) => b.responsedescription = Some(buf.to_string())
            None => ()
          }
          desc_buf = None
        }
        match pending {
          Some((pending_name, ns_uri, buf)) =>
            if name.local_name == pending_name {
              push_prop({
                name: pending_name,
                ns_uri,
                value: buf.to_string(),
                status: 200,
              })
              pending = None
            }
          None => ()
        }
        if is_dav_name(name, "propstat") {
          flush_propstat()
        }
        if is_dav_name(name, "response") {
          finish_response()
        }
        ignore(stack.pop())
      }
      _ => ()
    }
  }
  resources
}
