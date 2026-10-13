// `If` 请求头渲染：锁令牌（无标签列表）与通用条件列表（RFC 4918 §10.4）。
// 只负责拼字符串与本地校验，不发请求；落到请求头上见 client.mbt。
// 单独成文件以遵守单文件行数上限（AGENTS.md RL-04）。

///|
/// 归一化锁令牌为 `Lock-Token` 头形态：`<令牌>`。
/// 令牌可能自带尖括号（`Lock-Token` 响应头就是这种形状），也可能不带，
/// 统一只包一层，不会出现 `<<令牌>>`。
fn lock_token_uri(token : String) -> String {
  "<" + @types.normalize_lock_token(token) + ">"
}

///|
/// `If` 头里的锁令牌形态：`(<令牌>)`（RFC 4918 §10.4.1 的无标签列表）。
fn lock_token_if_value(token : String) -> String {
  "(" + lock_token_uri(token) + ")"
}

///|
/// 渲染单个 `If` 条件：可选的 `Not ` 前缀 + 状态令牌或实体标签
/// （RFC 4918 §10.4.2 的 `Condition`）。
fn render_if_condition(
  condition : @types.IfCondition,
  operation~ : String,
) -> String raise @types.WebdavError {
  let prefix = if condition.negated { "Not " } else { "" }
  match condition.kind {
    @types.IfConditionKind::StateToken => {
      let token = @types.normalize_lock_token(condition.value)
      if token == "" {
        // 空状态令牌既不合法也无从匹配，宁可本地报错也不发出去。
        raise @types.WebdavError::api(
          status=400,
          operation~,
          message="If 条件里的锁令牌不能为空",
        )
      }
      prefix + "<" + token + ">"
    }
    @types.IfConditionKind::EntityTag => prefix + "[" + condition.value + "]"
  }
}

///|
/// 渲染一个 `If` 列表：`(条件 条件 ...)`，带资源标签时前缀 `<标签>`。
/// 列表内多个条件是合取关系；资源标签只对它后面这一个列表生效。
fn render_if_list(
  list : @types.IfList,
  operation~ : String,
) -> String raise @types.WebdavError {
  if list.conditions.length() == 0 {
    raise @types.WebdavError::api(
      status=400,
      operation~,
      message="If 列表至少要有一个条件",
    )
  }
  let items : Array[String] = []
  for condition in list.conditions {
    items.push(render_if_condition(condition, operation~))
  }
  let body = "(" + items.join(" ") + ")"
  match list.resource_tag {
    Some(tag) => {
      if tag == "" {
        raise @types.WebdavError::api(
          status=400,
          operation~,
          message="If 列表的资源标签不能为空",
        )
      }
      "<" + tag + "> " + body
    }
    None => body
  }
}

///|
/// 渲染整个 `If` 头（不含头名）：通用条件列表在前，锁令牌列表在后，
/// 空格连接；没有可渲染的内容时返回空串。
///
/// 无标签列表与带标签列表不能出现在同一个 `If` 头里（RFC 4918 §10.4.2），
/// 混用时本地抛 `Api` 400，不浪费一次往返；带标签模式下锁令牌渲染成
/// `<url> (<令牌>)` 这个独立 production。
fn render_if_header(
  conditions : @types.Conditions,
  url~ : String,
  operation~ : String,
) -> String raise @types.WebdavError {
  let untagged : Array[String] = []
  let tagged : Array[String] = []
  for list in conditions.if_lists {
    let rendered = render_if_list(list, operation~)
    match list.resource_tag {
      Some(_) => tagged.push(rendered)
      None => untagged.push(rendered)
    }
  }
  let token = match conditions.lock_token {
    Some(raw) => @types.normalize_lock_token(raw)
    None => ""
  }
  if untagged.length() > 0 && tagged.length() > 0 {
    raise @types.WebdavError::api(
      status=400,
      operation~,
      message="If 头的无标签列表与带标签列表不能混用",
    )
  }
  if tagged.length() > 0 {
    if token != "" {
      tagged.push("<" + url + "> (" + lock_token_uri(token) + ")")
    }
    tagged.join(" ")
  } else {
    if token != "" {
      untagged.push("(" + lock_token_uri(token) + ")")
    }
    untagged.join(" ")
  }
}
