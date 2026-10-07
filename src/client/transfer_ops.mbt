// 移动与复制（MOVE / COPY）：Destination 头必须是绝对 URL，由
// base_url + 编码后的目标路径拼出；Overwrite 头控制覆盖语义；
// Depth 头控制 COPY 对集合是否递归（`0` 为浅拷贝）。

///|
/// 移动 / 重命名（MOVE）。
///
/// - `src` / `dst`：相对 base_url 的源与目标路径；
/// - `overwrite`：目标已存在时是否覆盖，默认 `true`；为 `false` 且目标
///   存在时服务端返回 412（抛 `Api` 错误）；
/// - `depth`：省略则不发 `Depth` 头（对已存在的集合服务端默认递归）；
///   显式给 `Zero` 可对目录做浅移动（支持该语义的服务端较少）；
/// - 207：服务端逐资源返回结果，有失败条目时抛 `Partial`。
pub async fn WebdavClient::move_path(
  self : WebdavClient,
  src~ : String,
  dst~ : String,
  overwrite? : Bool,
  depth? : @types.Depth,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let response = self.send(
    operation="MOVE",
    http_method=@config.Method::Other("MOVE"),
    path=src,
    headers=transfer_headers(self, dst, overwrite, depth),
    conditions?,
    signal?,
    ok=[201, 204, 207],
  )
  check_status_allow_partial(response, operation="MOVE", ok=[201, 204, 207])
}

///|
/// 复制（COPY）。参数语义与 `move_path` 一致，另加 `Depth`：
/// 省略为服务端默认（集合通常递归），`Zero` 做浅拷贝
/// （只建目标集合并复制属性，不复制子项，RFC 4918 §9.8.3）。
pub async fn WebdavClient::copy_path(
  self : WebdavClient,
  src~ : String,
  dst~ : String,
  overwrite? : Bool,
  depth? : @types.Depth,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let response = self.send(
    operation="COPY",
    http_method=@config.Method::Other("COPY"),
    path=src,
    headers=transfer_headers(self, dst, overwrite, depth),
    conditions?,
    signal?,
    ok=[201, 204, 207],
  )
  check_status_allow_partial(response, operation="COPY", ok=[201, 204, 207])
}

///|
/// MOVE / COPY 的公共请求头：绝对 Destination、Overwrite，
/// 以及可选的 Depth。
fn transfer_headers(
  client : WebdavClient,
  dst : String,
  overwrite : Bool?,
  depth : @types.Depth?,
) -> Array[(String, String)] {
  let headers : Array[(String, String)] = [
    ("Destination", client.url_for(dst)),
    ("Overwrite", if overwrite.unwrap_or(true) { "T" } else { "F" }),
  ]
  match depth {
    Some(value) => headers.push(("Depth", value.to_header()))
    None => ()
  }
  headers
}
