// WebDAV 客户端的公共类型：配置、资源信息、传输进度与统一错误。
// 这些类型贯穿所有实现包，也是对外 API 的契约（根包做薄重导出）。

///|
/// 客户端配置，字段可直接构造，未填字段取 `Default`（`None` / 超时默认值）。
///
/// - `base_url`：服务器根地址，如 `"http://127.0.0.1:8080/dav/"`，
///   末尾多余的 `/` 会被内部规范化容忍；
/// - `username` / `password`：Basic Auth 凭据，均为 `None` 时不携带认证；
/// - `timeout_ms`：单请求超时毫秒数，`None` 时取 `DEFAULT_TIMEOUT_MS`。
pub(all) struct WebdavConfig {
  base_url : String
  username : String?
  password : String?
  timeout_ms : Int?
} derive(Default)

///|
pub extend WebdavConfig with Default::{default}

///|
/// 默认单请求超时：30 秒。
pub const DEFAULT_TIMEOUT_MS : Int = 30_000

///|
/// PROPFIND 解析出的资源条目（文件或目录）。
pub(all) struct FileInfo {
  /// 服务端返回的原始 href（URL 编码路径，如 `/dav/%E4%B8%AD.md`）
  href : String
  /// href 末段 percent 解码后的显示名；根路径本身为空字符串
  name : String
  /// 是否为目录（WebDAV 集合，collection）
  is_dir : Bool
  /// 字节大小；目录或未知时为 `None`
  content_length : Int?
  /// MIME 类型；目录通常为 `None`
  content_type : String?
  /// 最后修改时间（RFC 1123 格式原样，如 `Mon, 10 Mar 2025 12:00:00 GMT`）
  last_modified : String?
  /// 创建时间（RFC 3339 格式原样，部分服务器不返回）
  created : String?
  /// ETag（含引号原样）
  etag : String?
}

///|
/// 传输进度快照，由上传 / 下载回调接收。
pub(all) struct Progress {
  /// 已传输字节数
  loaded : Int
  /// 总字节数；服务端未返回长度时为 `None`
  total : Int?
}

///|
/// 完成比例 `0.0 ~ 1.0`；总长未知或为零时为 `None`。
pub fn Progress::percent(self : Progress) -> Double? {
  match self.total {
    Some(total) if total > 0 =>
      Some(self.loaded.to_double() / total.to_double())
    _ => None
  }
}

///|
/// 错误分类：可按「该怎么处理」分支。
pub(all) enum WebdavErrorDetail {
  /// 网络 / HTTP 协议层错误（来自 moonhttp）
  Http(@moonhttp.HttpError)
  /// WebDAV 响应的 XML 解析失败
  Xml(@xml.XmlError)
  /// 服务端返回了该操作不期望的状态码，`message` 为中文人读描述
  Api(status~ : Int, operation~ : String, message~ : String)
}

///|
/// 所有 WebDAV 操作的统一错误（单构造器包装，MoonBit 错误类型约定）。
/// 用 `detail()` 取出分类后模式匹配，`to_string()` 得中文人读描述。
pub(all) suberror WebdavError {
  WebdavError(WebdavErrorDetail)
}

///|
/// 取出错误分类。
pub fn WebdavError::detail(self : WebdavError) -> WebdavErrorDetail {
  match self {
    WebdavError(detail) => detail
  }
}

///|
/// 包装网络 / HTTP 协议层错误。
pub fn WebdavError::http(error : @moonhttp.HttpError) -> WebdavError {
  WebdavError(Http(error))
}

///|
/// 包装 XML 解析错误。
pub fn WebdavError::xml(error : @xml.XmlError) -> WebdavError {
  WebdavError(Xml(error))
}

///|
/// 构造「非期望状态码」错误。
pub fn WebdavError::api(
  status~ : Int,
  operation~ : String,
  message~ : String,
) -> WebdavError {
  WebdavError(Api(status~, operation~, message~))
}

///|
/// 人读的中文错误描述，便于日志与字符串插值。
pub fn WebdavError::to_string(self : WebdavError) -> String {
  match self.detail() {
    Http(error) => "网络/HTTP 错误: " + error.to_string()
    Xml(error) => "XML 解析错误: " + error.to_string()
    Api(status~, operation~, message~) =>
      "\{operation} 失败: HTTP \{status} \{message}"
  }
}

///|
/// 渲染与 `WebdavError::to_string` 一致，`println` / 插值可直接使用。
pub impl Show for WebdavError with fn to_string(self) {
  self.to_string()
}

///|
pub extend WebdavError with Show::{output}
