// 移动与复制（MOVE / COPY）：Destination 头必须是绝对 URL，
// 由 base_url + 编码后的目标路径拼出；Overwrite 头控制覆盖语义。

///|
/// 移动 / 重命名（MOVE）。
///
/// - `src` / `dst`：相对 base_url 的源与目标路径；
/// - `overwrite`：目标已存在时是否覆盖，默认 `true`；
///   为 `false` 且目标存在时服务端返回 412（抛 `Api` 错误）。
pub async fn WebdavClient::move_path(
  self : WebdavClient,
  src~ : String,
  dst~ : String,
  overwrite? : Bool,
) -> Unit raise @types.WebdavError {
  ignore(
    self.send(
      operation="MOVE",
      http_method=@config.Method::Other("MOVE"),
      path=src,
      headers=[
        ("Destination", self.url_for(dst)),
        ("Overwrite", if overwrite.unwrap_or(true) { "T" } else { "F" }),
      ],
      ok=[201, 204],
    ),
  )
}

///|
/// 复制（COPY）。参数语义与 `move_path` 一致。
pub async fn WebdavClient::copy_path(
  self : WebdavClient,
  src~ : String,
  dst~ : String,
  overwrite? : Bool,
) -> Unit raise @types.WebdavError {
  ignore(
    self.send(
      operation="COPY",
      http_method=@config.Method::Other("COPY"),
      path=src,
      headers=[
        ("Destination", self.url_for(dst)),
        ("Overwrite", if overwrite.unwrap_or(true) { "T" } else { "F" }),
      ],
      ok=[201, 204],
    ),
  )
}
