// 锁相关的 XML：LOCK 请求体（lockinfo）生成与 lockdiscovery 解析。
// 解析走 NamespaceReader 事件流，按 local_name + 命名空间（DAV:）匹配，
// 与 207 解析（multistatus.mbt）同一口径，对前缀写法不敏感。
// 单独成文件以遵守单文件行数上限（AGENTS.md RL-04）。

///|
/// 生成 LOCK 请求体（RFC 4918 §9.10.1 的 lockinfo）：独占写锁。
/// `owner` 作为 `<D:owner>` 的文本内容，省略时不发该元素；
/// 文本里的 `&` / `<` 由 Writer 负责转义。
pub fn lockinfo_body(owner? : String) -> String raise @xml.WriterError {
  let writer = @xml.Writer::new()
  writer.start_element("D:lockinfo", [("xmlns:D", "DAV:")])
  writer.start_element("D:lockscope", [])
  writer.empty_element("D:exclusive", [])
  writer.end_element("D:lockscope")
  writer.start_element("D:locktype", [])
  writer.empty_element("D:write", [])
  writer.end_element("D:locktype")
  match owner {
    Some(text) => {
      writer.start_element("D:owner", [])
      writer.text(text)
      writer.end_element("D:owner")
    }
    None => ()
  }
  writer.end_element("D:lockinfo")
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + writer.to_string()
}

///|
/// 单个 `activelock` 解析过程中的累积器。
/// `scope` 预先按独占处理（RFC 4918 §14.11 里 lockscope 必填，
/// 但服务端漏回时按独占更符合客户端预期）；`owner` 用缓冲是因为
/// `<D:owner>` 里可以嵌 `<D:href>`，两段文本都要算进 owner。
priv struct LockBuilder {
  mut token : String
  mut scope : String
  mut depth : String?
  mut timeout : String?
  mut lockroot : String?
  mut owner : StringBuilder?
}

///|
fn LockBuilder::new() -> LockBuilder {
  {
    token: "",
    scope: "exclusive",
    depth: None,
    timeout: None,
    lockroot: None,
    owner: None,
  }
}

///|
/// activelock 内需要按文本累积的叶子元素（href 另有归属判断）。
fn is_lock_leaf(name : @xml.XmlName) -> Bool {
  is_dav_name(name, "href") ||
  is_dav_name(name, "timeout") ||
  is_dav_name(name, "depth")
}

///|
/// 解析 lockdiscovery，返回文档里出现的全部 activelock。
/// 同一解析器同时服务 LOCK 响应体与 PROPFIND 的 207 响应体，
/// 因此不假定 activelock 的绝对嵌套深度。
/// 没有锁令牌的 activelock 会被丢弃（无令牌的锁对调用方没有意义）。
pub fn parse_lockdiscovery(
  xml_text : String,
) -> Array[@types.ActiveLock] raise @xml.XmlError {
  let reader = @xml.NamespaceReader::from_string(xml_text)
  let locks : Array[@types.ActiveLock] = []
  // 打开元素的 local_name 栈，用于判断 href 的父元素
  let stack : Array[String] = []
  let mut builder : LockBuilder? = None
  // 正在累积文本的叶子：(局部名, 文本缓冲)
  let mut leaf : (String, StringBuilder)? = None
  fn set_token(text : String) -> Unit {
    match builder {
      Some(b) => b.token = @types.normalize_lock_token(text)
      None => ()
    }
  }
  fn set_scope(value : String) -> Unit {
    match builder {
      Some(b) => b.scope = value
      None => ()
    }
  }
  fn append_owner(text : String) -> Unit {
    match builder {
      Some(b) =>
        match b.owner {
          Some(buf) => buf.write_string(text)
          None => ()
        }
      None => ()
    }
  }
  // activelock 结束：收条（无令牌则丢弃）并清空累积状态
  fn finish_active_lock() -> Unit {
    match builder {
      Some(b) => {
        if b.token != "" {
          locks.push({
            token: b.token,
            scope: b.scope,
            depth: b.depth,
            owner: match b.owner {
              Some(buf) => {
                let text = buf.to_string().trim().to_owned()
                if text == "" {
                  None
                } else {
                  Some(text)
                }
              }
              None => None
            },
            timeout: b.timeout,
            lockroot: b.lockroot,
          })
        }
        builder = None
        leaf = None
      }
      None => ()
    }
  }
  // 叶子结束：按局部名与父元素归属文本
  fn close_leaf(name : @xml.XmlName) -> Unit {
    let (leaf_name, buf) = match leaf {
      Some(entry) => entry
      None => return
    }
    if leaf_name != name.local_name {
      return
    }
    let text = buf.to_string()
    leaf = None
    let parent = if stack.length() >= 2 {
      Some(stack[stack.length() - 2])
    } else {
      None
    }
    if is_dav_name(name, "href") {
      if parent == Some("locktoken") {
        set_token(text)
      } else if parent == Some("lockroot") {
        match builder {
          Some(b) => b.lockroot = Some(text.trim().to_owned())
          None => ()
        }
      } else if parent == Some("owner") {
        append_owner(text)
      }
    } else if is_dav_name(name, "timeout") {
      match builder {
        Some(b) => b.timeout = Some(text.trim().to_owned())
        None => ()
      }
    } else if is_dav_name(name, "depth") {
      match builder {
        Some(b) => b.depth = Some(text.trim().to_owned())
        None => ()
      }
    }
  }
  // 文本归属：叶子缓冲 > owner 缓冲
  fn write_text(text : String) -> Unit {
    match leaf {
      Some((_, buf)) => buf.write_string(text)
      None => append_owner(text)
    }
  }
  // 开始一个 activelock 内的元素（Start 与 Empty 共用）
  fn open_lock_element(name : @xml.XmlName) -> Unit {
    if is_dav_name(name, "exclusive") {
      set_scope("exclusive")
    } else if is_dav_name(name, "shared") {
      set_scope("shared")
    } else if is_dav_name(name, "owner") {
      match builder {
        Some(b) => b.owner = Some(StringBuilder())
        None => ()
      }
    } else if is_lock_leaf(name) {
      leaf = Some((name.local_name, StringBuilder()))
    }
  }
  while true {
    let event = reader.read_event()
    match event.kind {
      Eof => break
      Start(el) => {
        let name = el.name
        stack.push(name.local_name)
        if is_dav_name(name, "activelock") {
          builder = Some(LockBuilder::new())
          leaf = None
        } else if builder is Some(_) {
          open_lock_element(name)
        }
      }
      Empty(el) => {
        // 自闭合元素：等价于 Start + End，只是没有文本
        let name = el.name
        stack.push(name.local_name)
        if is_dav_name(name, "activelock") {
          builder = Some(LockBuilder::new())
          finish_active_lock()
        } else if builder is Some(_) {
          open_lock_element(name)
        }
        ignore(stack.pop())
      }
      Text(text) => write_text(text)
      CData(text) => write_text(text)
      End(name) => {
        if is_dav_name(name, "activelock") {
          finish_active_lock()
        } else if builder is Some(_) && is_lock_leaf(name) {
          close_leaf(name)
        }
        ignore(stack.pop())
      }
      _ => ()
    }
  }
  locks
}
