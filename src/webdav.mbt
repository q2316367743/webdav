// 门面：重导出公开 API，实现见 src/client、src/xmlutil、src/types。
// 用户侧统一以 `@webdav.xxx` 访问；方法（put_file 等）随 WebdavClient
// 类型一并可用，无需单独重导出。

///|
pub using @types {
  type WebdavConfig,
  type FileInfo,
  type Progress,
  type WebdavError,
  type WebdavErrorDetail,
}

///|
pub using @client {type WebdavClient}

///|
/// 默认单请求超时（毫秒），与 `@types.DEFAULT_TIMEOUT_MS` 同值。
pub const DEFAULT_TIMEOUT_MS : Int = @types.DEFAULT_TIMEOUT_MS

///|
/// 创建 WebDAV 客户端：所有操作以方法形式挂在返回值上。
///
/// 示例：
/// ```
/// let client = @webdav.create_webdav_client({
///   base_url: "http://127.0.0.1:8080/dav/",
///   username: Some("user"),
///   password: Some("pass"),
///   timeout_ms: None,
/// })
/// ```
pub fn create_webdav_client(
  config : @types.WebdavConfig,
) -> @client.WebdavClient {
  @client.create_webdav_client(config)
}

///|
/// 创建使用指定传输层的客户端：测试注入 MockTransport，
/// 或自定义连接 / 代理行为。
pub fn create_webdav_client_with_transport(
  config : @types.WebdavConfig,
  transport : &@transport.Transport,
) -> @client.WebdavClient {
  @client.create_webdav_client_with_transport(config, transport)
}

///|
/// 自定义属性（死属性）的默认命名空间，与 `@client.DEFAULT_PROP_NS` 同值。
pub const DEFAULT_PROP_NS : String = @client.DEFAULT_PROP_NS
