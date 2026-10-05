// 目录与属性操作：MKCOL / DELETE / HEAD / PROPFIND（list / stat /
// get_properties）与 PROPPATCH（set_properties）。

///|
/// 自定义属性（死属性）的默认命名空间。
pub const DEFAULT_PROP_NS : String = "urn:q2316367743:webdav:prop"

///|
/// 创建目录（MKCOL）。单级创建：父目录不存在时服务端通常返回 409。
pub async fn WebdavClient::mkdir(
  self : WebdavClient,
  path~ : String,
) -> Unit raise @types.WebdavError {
  ignore(
    self.send(
      operation="MKCOL",
      http_method=@config.Method::Other("MKCOL"),
      path~,
      ok=[201],
    ),
  )
}

///|
/// 删除文件或目录（DELETE，目录要求为空或服务端支持递归）。
pub async fn WebdavClient::delete(
  self : WebdavClient,
  path~ : String,
) -> Unit raise @types.WebdavError {
  ignore(
    self.send(operation="DELETE", http_method=@config.Method::Delete, path~, ok=[
      200, 204,
    ]),
  )
}

///|
/// 资源是否存在（HEAD）：200 / 204 为存在，404 为不存在，其余抛错。
pub async fn WebdavClient::exists(
  self : WebdavClient,
  path~ : String,
) -> Bool raise @types.WebdavError {
  let response = self.send(
    operation="HEAD",
    http_method=@config.Method::Head,
    path~,
    ok=[200, 204, 404],
  )
  response.status == 200 || response.status == 204
}

///|
/// 列目录（PROPFIND Depth:1 allprop）：返回直接子项，不含目录自身。
/// 目录 href 与用户路径的对齐会同时做「percent 解码 + 尾斜杠归一 +
/// 挂载前缀还原」，不依赖服务端的编码风格。
pub async fn WebdavClient::list(
  self : WebdavClient,
  path~ : String,
) -> Array[@types.FileInfo] raise @types.WebdavError {
  let resources = self.propfind(path~, depth="1")
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
/// 获取单个资源的属性（PROPFIND Depth:0 allprop）。
/// 资源不存在时服务端返回 404（抛 `Api` 错误）。
pub async fn WebdavClient::stat(
  self : WebdavClient,
  path~ : String,
) -> @types.FileInfo raise @types.WebdavError {
  let resources = self.propfind(path~, depth="0")
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
      ok=[207],
    ),
  )
}

///|
/// 读取自定义属性（PROPFIND 按名请求）：返回 属性名 → 值，
/// 服务端未存储的名字不出现在结果中。
pub async fn WebdavClient::get_properties(
  self : WebdavClient,
  path~ : String,
  names~ : Array[String],
  ns_uri? : String,
) -> Map[String, String] raise @types.WebdavError {
  let ns = ns_uri.unwrap_or(DEFAULT_PROP_NS)
  let body = @xmlutil.propfind_named_body(names, ns_uri=ns) catch {
    error => raise invalid_prop_name(error)
  }
  let resources = self.send_propfind(path~, depth="0", body~)
  let result : Map[String, String] = Map([])
  if resources.length() > 0 {
    for prop in resources[0].props {
      if prop.ns_uri == Some(ns) {
        result.set(prop.name, prop.value)
      }
    }
  }
  result
}

///|
/// 发送 allprop 的 PROPFIND 并解析 207 响应。
async fn WebdavClient::propfind(
  self : WebdavClient,
  path~ : String,
  depth~ : String,
) -> Array[@xmlutil.ParsedResource] raise @types.WebdavError {
  self.send_propfind(path~, depth~, body=@xmlutil.propfind_allprop_body())
}

///|
/// 发送 PROPFIND（指定请求体）并解析 207 响应。
async fn WebdavClient::send_propfind(
  self : WebdavClient,
  path~ : String,
  depth~ : String,
  body~ : String,
) -> Array[@xmlutil.ParsedResource] raise @types.WebdavError {
  let response = self.send(
    operation="PROPFIND",
    http_method=@config.Method::Other("PROPFIND"),
    path~,
    headers=[
      ("Depth", depth),
      ("Content-Type", "application/xml; charset=utf-8"),
    ],
    body~,
    ok=[207],
  )
  @xmlutil.parse_multistatus(response.text()) catch {
    error => raise @types.WebdavError::xml(error)
  }
}

///|
/// href 与请求的服务器路径是否指向同一资源：
/// percent 解码 + 去尾斜杠后比较。
fn same_resource(href : String, server_path : String) -> Bool {
  fn trim_slash(text : String) -> String {
    if text.has_suffix("/") && text.length() > 1 {
      text[:text.length() - 1].to_owned()
    } else {
      text
    }
  }
  trim_slash(@types.percent_decode(href)) == trim_slash(server_path)
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
