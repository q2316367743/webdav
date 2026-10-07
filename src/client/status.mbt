// 响应状态码判定：期望状态码集合、失败时的中文注解与响应体摘要、
// 207 Multi-Status 的失败条目提取。与具体操作解耦，单独成文件（RL-04）。

///|
/// 常见 WebDAV 状态码的中文注解（用于 Api 错误消息）。
fn status_message(status : Int) -> String {
  match status {
    200 => "成功"
    201 => "已创建"
    204 => "成功（无响应体）"
    207 => "Multi-Status"
    301 | 302 | 307 | 308 => "重定向"
    400 => "请求不合法"
    401 => "未认证（检查用户名 / 密码）"
    403 => "无权限"
    404 => "资源不存在"
    405 => "方法不允许（目标已存在或服务器不支持该操作）"
    409 => "冲突（父目录不存在？）"
    412 => "前置条件失败（目标已存在且不允许覆盖？）"
    423 => "资源被锁定"
    502 | 504 => "网关错误"
    507 => "存储空间不足"
    _ => "服务端返回异常状态"
  }
}

///|
/// 从响应体里取一段摘要（最多 200 字符）拼进错误消息；
/// 响应体为空时返回空串。部分服务端用响应体说明失败原因。
fn body_hint(response : @moonhttp.Response) -> String {
  let text = response.text().trim()
  if text.length() == 0 {
    ""
  } else if text.length() > 200 {
    "（响应体：" + text[:200].to_owned() + "…）"
  } else {
    "（响应体：" + text.to_owned() + "）"
  }
}

///|
/// 校验响应状态码：不在 ok 集合内则抛 `Api` 错误。
fn check_status(
  response : @moonhttp.Response,
  operation~ : String,
  ok~ : Array[Int],
) -> @moonhttp.Response raise @types.WebdavError {
  if ok.contains(response.status) {
    response
  } else {
    raise @types.WebdavError::api(
      status=response.status,
      operation~,
      message=status_message(response.status) + body_hint(response),
    )
  }
}

///|
/// 从 207 响应里提取失败条目：`response` 级状态码非 2xx 的资源。
/// 没有 `<D:status>` 的响应（纯 PROPFIND 形态）视为无失败。
fn failures_from_multistatus(
  response : @moonhttp.Response,
) -> Array[@types.ResourceFailure] raise @types.WebdavError {
  let resources = @xmlutil.parse_multistatus(response.text()) catch {
    error => raise @types.WebdavError::xml(error)
  }
  let failures : Array[@types.ResourceFailure] = []
  for resource in resources {
    match resource.status {
      Some(status) =>
        if status < 200 || status >= 300 {
          failures.push({
            href: resource.href,
            status,
            message: status_message(status),
          })
        }
      None => ()
    }
  }
  failures
}

///|
/// 允许 207 的状态校验：先按 ok 集合放行，若响应是 207，则从响应体里
/// 找失败条目——有失败抛 `Partial`，全是 2xx 视为整体成功。
fn check_status_allow_partial(
  response : @moonhttp.Response,
  operation~ : String,
  ok~ : Array[Int],
) -> Unit raise @types.WebdavError {
  let checked = check_status(response, operation~, ok~)
  if checked.status == 207 {
    let failures = failures_from_multistatus(checked)
    if failures.length() > 0 {
      raise @types.WebdavError::partial(operation~, failures~)
    }
  }
}
