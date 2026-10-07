// 上传 / 下载的返回结果：把响应头里对调用方有用的元数据（ETag、
// Last-Modified、Location、Content-Type）带出来，供乐观并发控制
// （下一次请求带 `If-Match`）与条件缓存复用。

///|
/// `put_file` 的结果。
pub(all) struct PutResult {
  /// HTTP 状态码（200 覆盖写 / 201 新建 / 204 无响应体）
  status : Int
  /// 是否新建了资源（状态码为 201）
  created : Bool
  /// 响应 `ETag` 头（含引号原样；服务端未返回时为 `None`）
  etag : String?
  /// 响应 `Last-Modified` 头
  last_modified : String?
  /// 响应 `Location` 头
  location : String?
}

///|
/// `get_file` 的结果：内容与响应元数据。
pub(all) struct GetResult {
  /// 响应体字节
  content : Bytes
  /// HTTP 状态码
  status : Int
  /// 响应 `Content-Type` 头
  content_type : String?
  /// 响应 `Content-Length` 头（服务端未返回时为 `None`）
  content_length : Int?
  /// 响应 `ETag` 头
  etag : String?
  /// 响应 `Last-Modified` 头
  last_modified : String?
}
