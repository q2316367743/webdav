// 上传 / 下载的返回结果：把响应头里对调用方有用的元数据（ETag、
// Last-Modified、Location、Content-Type）带出来，供乐观并发控制
// （下一次请求带 `If-Match`）与条件缓存复用。

///|
/// `put_file` 的结果。
pub(all) struct PutResult {
  /// HTTP 状态码（200 覆盖写 / 201 新建 / 204 无响应体）
  status : Int32
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
  /// 响应体字节（带 `range?` 请求且被服务端接受时为 206 的区间内容）
  content : Bytes
  /// HTTP 状态码（200 全量 / 206 区间）
  status : Int32
  /// 响应 `Content-Type` 头
  content_type : String?
  /// 响应 `Content-Length` 头（服务端未返回时为 `None`；
  /// 206 时是**区间**长度而非资源总长）
  content_length : Int32?
  /// 响应 `ETag` 头
  etag : String?
  /// 响应 `Last-Modified` 头
  last_modified : String?
  /// 206 响应的 `Content-Range` 解析结果（区间起止与资源总长）；
  /// 非 206 响应、或服务端返回 206 却未带可解析的该头时为 `None`
  content_range : ContentRange?
}
