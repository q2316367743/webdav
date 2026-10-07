// 目录与属性操作：MKCOL / DELETE / PROPFIND（list / stat / get_properties）
// 与 PROPPATCH（set_properties）。
// 存在性判断与能力探测见 probe_ops.mbt。

///|
/// 自定义属性（死属性）的默认命名空间。
pub const DEFAULT_PROP_NS : String = "urn:q2316367743:webdav:prop"

///|
/// 创建目录（MKCOL）。单级创建：父目录不存在时服务端通常返回 409。
pub async fn WebdavClient::mkdir(
  self : WebdavClient,
  path~ : String,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  ignore(
    self.send(
      operation="MKCOL",
      http_method=@config.Method::Other("MKCOL"),
      path~,
      ok=[201],
      signal?,
    ),
  )
}

///|
/// 删除文件或目录（DELETE，目录要求为空或服务端支持递归）。
///
/// 放行 207：部分服务端对批量 / 递归删除返回 Multi-Status，
/// 只要有资源没删成功就抛 `Partial`（`failures` 列出失败条目）。
pub async fn WebdavClient::delete(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let response = self.send(
    operation="DELETE",
    http_method=@config.Method::Delete,
    path~,
    conditions?,
    signal?,
    ok=[200, 204, 207],
  )
  check_status_allow_partial(response, operation="DELETE", ok=[200, 204, 207])
}

///|
/// 列目录（PROPFIND allprop）：默认 `Depth:1` 返回直接子项，不含目录自身。
///
/// - `depth`：`One`（默认，直接子项）/ `Infinity`（整棵子树，见
///   `list_recursive`）/ `Zero`（只有目录自身，结果通常为空）；
/// - href 与服务端路径的对齐统一走 `@types.href_to_path`
///   （剥绝对 URL 前缀、丢 query / fragment、percent 解码、去尾斜杠）。
pub async fn WebdavClient::list(
  self : WebdavClient,
  path~ : String,
  depth? : @types.Depth,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Array[@types.FileInfo] raise @types.WebdavError {
  let resources = self.propfind(
    path~,
    depth=depth.unwrap_or(@types.Depth::One),
    conditions?,
    signal?,
  )
  let server_path = base_path_prefix(self.base_url) +
    (if path.has_prefix("/") { path } else { "/" + path })
  let items : Array[@types.FileInfo] = []
  for resource in resources {
    if !same_resource(resource.href, server_path) {
      items.push(resource.to_file_info())
    }
  }
  items
}

///|
/// 递归列出整棵子树（PROPFIND `Depth:infinity`）。
/// 服务端可能限制深度并返回 403，调用方可自行降级为逐层 `list`。
pub async fn WebdavClient::list_recursive(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Array[@types.FileInfo] raise @types.WebdavError {
  self.list(path~, depth=@types.Depth::Infinity, conditions?, signal?)
}

///|
/// 获取单个资源的属性（PROPFIND `Depth:0` allprop）。
/// 资源不存在时服务端返回 404（抛 `Api` 错误）。
pub async fn WebdavClient::stat(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> @types.FileInfo raise @types.WebdavError {
  let resources = self.propfind(
    path~,
    depth=@types.Depth::Zero,
    conditions?,
    signal?,
  )
  if resources.length() == 0 {
    raise @types.WebdavError::api(
      status=207,
      operation="PROPFIND",
      message="响应中没有资源条目",
    )
  }
  resources[0].to_file_info()
}

///|
/// 写入自定义属性（PROPPATCH set）。
///
/// - `props`：(属性名, 值) 列表；
/// - `ns_uri`：属性命名空间，默认 `DEFAULT_PROP_NS`；
///   属性名需为合法 XML 名（非法时抛 `Api` 400）。
pub async fn WebdavClient::set_properties(
  self : WebdavClient,
  path~ : String,
  props~ : Array[(String, String)],
  ns_uri? : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let body = @xmlutil.proppatch_set_body(
    props,
    ns_uri=ns_uri.unwrap_or(DEFAULT_PROP_NS),
  ) catch {
    error => raise invalid_prop_name(error)
  }
  ignore(
    self.send(
      operation="PROPPATCH",
      http_method=@config.Method::Other("PROPPATCH"),
      path~,
      headers=[("Content-Type", "application/xml; charset=utf-8")],
      body~,
      conditions?,
      signal?,
      ok=[207],
    ),
  )
}

///|
/// 读取自定义属性（PROPFIND 按名请求）：返回 属性名 → 值，
/// 服务端没有的属性（404 propstat）不出现在结果中。
/// 需要区分「没有该属性」与「值为空」时用 `get_properties_with_status`。
pub async fn WebdavClient::get_properties(
  self : WebdavClient,
  path~ : String,
  names~ : Array[String],
  ns_uri? : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Map[String, String] raise @types.WebdavError {
  let results = self.get_properties_with_status(
    path~,
    names~,
    ns_uri?,
    conditions?,
    signal?,
  )
  let map : Map[String, String] = Map([])
  for prop in results {
    if prop.status >= 200 && prop.status < 300 {
      map.set(prop.name, prop.value)
    }
  }
  map
}

///|
/// 读取自定义属性并保留每个属性的状态码：404 表示服务端没有这个属性，
/// 与「属性值为空串」区分开（部分服务端对未存储的死属性回 404 propstat）。
pub async fn WebdavClient::get_properties_with_status(
  self : WebdavClient,
  path~ : String,
  names~ : Array[String],
  ns_uri? : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Array[@types.PropResult] raise @types.WebdavError {
  let ns = ns_uri.unwrap_or(DEFAULT_PROP_NS)
  let body = @xmlutil.propfind_named_body(names, ns_uri=ns) catch {
    error => raise invalid_prop_name(error)
  }
  let resources = self.send_propfind(
    path~,
    depth=@types.Depth::Zero,
    body~,
    conditions?,
    signal?,
  )
  let results : Array[@types.PropResult] = []
  if resources.length() > 0 {
    for prop in resources[0].props {
      if prop.ns_uri == Some(ns) {
        results.push({
          name: prop.name,
          value: prop.value,
          status: prop.status,
        })
      }
    }
  }
  results
}

///|
/// 发送 allprop 的 PROPFIND 并解析 207 响应。
async fn WebdavClient::propfind(
  self : WebdavClient,
  path~ : String,
  depth~ : @types.Depth,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Array[@xmlutil.ParsedResource] raise @types.WebdavError {
  self.send_propfind(
    path~,
    depth~,
    body=@xmlutil.propfind_allprop_body(),
    conditions?,
    signal?,
  )
}

///|
/// 发送 PROPFIND（指定请求体）并解析 207 响应。
async fn WebdavClient::send_propfind(
  self : WebdavClient,
  path~ : String,
  depth~ : @types.Depth,
  body~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Array[@xmlutil.ParsedResource] raise @types.WebdavError {
  let response = self.send(
    operation="PROPFIND",
    http_method=@config.Method::Other("PROPFIND"),
    path~,
    headers=[
      ("Depth", depth.to_header()),
      ("Content-Type", "application/xml; charset=utf-8"),
    ],
    body~,
    conditions?,
    signal?,
    ok=[207],
  )
  @xmlutil.parse_multistatus(response.text()) catch {
    error => raise @types.WebdavError::xml(error)
  }
}

///|
/// href 与请求的服务器路径是否指向同一资源（归一后比较）。
fn same_resource(href : String, server_path : String) -> Bool {
  @types.href_to_path(href) == @types.href_to_path(server_path)
}

///|
/// 属性名 / 请求体非法（WriterError）转成的 400 Api 错误。
fn invalid_prop_name(error : @xml.WriterError) -> @types.WebdavError {
  let detail = match error {
    InvalidName(_) => "属性名不构成合法 XML 名"
    InvalidContent(_) => "属性值包含非法内容"
    InvalidStructure(_) => "XML 结构非法"
    InvalidDeclaration(_) => "XML 声明非法"
  }
  @types.WebdavError::api(status=400, operation="PROPPATCH", message=detail)
}
