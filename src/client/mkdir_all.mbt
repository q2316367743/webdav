// 递归建目录（`mkdir -p` 语义）：把路径切成逐级前缀，自顶向下依次 MKCOL。
// 单级 `mkdir` 在 dir_ops.mbt；本文件只放多级创建与路径切分（RL-04 拆分）。

///|
/// 递归创建目录（`mkdir -p` 语义）：对 `path` 的每一级依次发 MKCOL，
/// 父级先于子级。
///
/// - 某级已存在时跳过：服务端按 RFC 4918 §9.3.1 回 405（Method Not Allowed），
///   因此对已存在的目录重复调用是幂等的，末级已存在也不算失败；
/// - 回 409（Conflict，父目录不存在）时用 PROPFIND `Depth:0` 复核该级是否
///   真的存在（并发创建 / 他人刚建好）：存在则跳过，不存在则原样抛出 409——
///   避免父级不是集合时「逐级跳过、最后假装成功」；
/// - `path` 为 `/`、空串或只有斜杠时（基地址自身，视作已存在）不发任何请求；
/// - 重复斜杠与结尾斜杠会折叠 / 忽略，每级都拼成以 `/` 开头的绝对路径；
/// - `conditions` 逐级生效（等价于逐级调用 `mkdir`），若带 `If-None-Match: *`
///   则已存在的层级会先回 412 而不是 405，需要幂等时不要传该条件。
pub async fn WebdavClient::mkdir_all(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  for target in collection_prefixes(path) {
    self.mkcol_tolerate_existing(path=target, conditions?, signal?)
  }
}

///|
/// 建一级目录并把「已存在」当作成功：405 直接跳过；409 先复核
/// （PROPFIND `Depth:0`）资源是否真的存在，确不存在才重新抛出原错误。
async fn WebdavClient::mkcol_tolerate_existing(
  self : WebdavClient,
  path~ : String,
  conditions? : @types.Conditions,
  signal? : @moonhttp.AbortSignal,
) -> Unit raise @types.WebdavError {
  let outcome : Result[Unit, @types.WebdavError] = try {
    self.mkdir(path~, conditions?, signal?)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => ()
    Err(error) =>
      match error.detail() {
        // 405：目标已存在（RFC 4918 §9.3.1），按 mkdir -p 语义当作成功
        Api(status=405, operation=_, message=_) => ()
        // 409：父级不存在或不是集合；复核存在性以兼容并发创建
        Api(status=409, operation=_, message=_) =>
          if self.exists_by_propfind(path~, conditions?, signal?) {
            ()
          } else {
            raise error
          }
        _ => raise error
      }
  }
}

///|
/// 把用户路径切成自顶向下的各级路径：`"a//b/"` → `["/a", "/a/b"]`。
/// 空段（重复 / 结尾斜杠）忽略；空串与 `"/"` 得空数组（基地址自身无需创建）。
fn collection_prefixes(path : String) -> Array[String] {
  let prefixes : Array[String] = []
  let current = StringBuilder()
  for segment in path.split("/") {
    if segment.length() == 0 {
      continue
    }
    current.write_char('/')
    current.write_view(segment)
    prefixes.push(current.to_string())
  }
  prefixes
}
