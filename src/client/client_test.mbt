// client 包黑盒用例（共享 helper 在本文件，同包 *_test.mbt 共用一个作用域）：
// 各操作的请求形状（方法 / URL / 头 / 请求体）与错误分支，
// 全部经 MockTransport 注入，不触网。

///|
/// 造一份 WebDAV 风格的原始响应。
fn dav_response(
  status : Int,
  content_type : String,
  body : String,
) -> @transport.RawResponse {
  {
    status,
    status_text: "",
    headers: @transport.Headers::new().set("Content-Type", content_type),
    set_cookies: [],
    body: @transport.ResponseBody::from_bytes(@utf8.encode(body)),
  }
}

///|
/// 在 `dav_response` 基础上追加响应头（DAV / Allow / Server / ETag 等）。
fn dav_response_with(
  status : Int,
  content_type : String,
  body : String,
  extra : Array[(String, String)],
) -> @transport.RawResponse {
  let mut headers = @transport.Headers::new().set("Content-Type", content_type)
  for entry in extra {
    // Headers::set 是不可变更新（返回新集合），必须接住返回值
    headers = headers.set(entry.0, entry.1)
  }
  {
    status,
    status_text: "",
    headers,
    set_cookies: [],
    body: @transport.ResponseBody::from_bytes(@utf8.encode(body)),
  }
}

///|
/// 按队列造响应的客户端：一次操作可能连发多个请求时使用
/// （如 HEAD 405 后回落到 PROPFIND 的 `exists`）。
fn dav_client_queue(
  responses : Array[@transport.RawResponse],
) -> (@client.WebdavClient, @transport.MockTransport) {
  let mock = @transport.MockTransport::from_responses(responses)
  let transport : &@transport.Transport = mock
  (
    @client.create_webdav_client_with_transport(
      {
        base_url: "http://127.0.0.1:8080/dav/",
        username: None,
        password: None,
        timeout_ms: None,
      },
      transport,
    ),
    mock,
  )
}

///|
/// 造一个打到 Mock 传输层的客户端，返回 (客户端, mock) 便于断言请求。
fn dav_client(
  response : @transport.RawResponse,
) -> (@client.WebdavClient, @transport.MockTransport) {
  let mock = @transport.MockTransport::new(response)
  let transport : &@transport.Transport = mock
  (
    @client.create_webdav_client_with_transport(
      {
        base_url: "http://127.0.0.1:8080/dav/",
        username: None,
        password: None,
        timeout_ms: None,
      },
      transport,
    ),
    mock,
  )
}

///|
/// 把抛出的 WebdavError 捕获为值（用 detail() 断言分类）。
async fn capture_error(
  run : async () -> Unit raise @types.WebdavError,
) -> @types.WebdavError? {
  try {
    run()
    None
  } catch {
    error => Some(error)
  }
}

///|
async test "mkdir 发出 MKCOL 到编码后的 URL" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(path="/相册/新建")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "MKCOL")
  assert_eq(
    request.url,
    "http://127.0.0.1:8080/dav/%E7%9B%B8%E5%86%8C/%E6%96%B0%E5%BB%BA",
  )
}

///|
async test "mkdir 目标已存在时抛 Api(405)" {
  let (client, _) = dav_client(dav_response(405, "text/plain", ""))
  let error = capture_error(() => client.mkdir(path="/exist")).unwrap()
  assert_true(error.detail() is Api(status=405, operation="MKCOL", message=_))
}

///|
async test "delete 发出 DELETE，404 抛 Api" {
  let (client, mock) = dav_client(dav_response(204, "text/plain", ""))
  client.delete(path="/a.txt")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "DELETE")
  assert_eq(request.url, "http://127.0.0.1:8080/dav/a.txt")
  let (missing, _) = dav_client(dav_response(404, "text/plain", ""))
  let error = capture_error(() => missing.delete(path="/gone")).unwrap()
  assert_true(error.detail() is Api(status=404, operation="DELETE", message=_))
}

///|
async test "exists 按 HEAD 的 200/404 返回布尔值" {
  let (hit, _) = dav_client(dav_response(200, "text/plain", ""))
  assert_true(hit.exists(path="/a.txt"))
  let (miss, _) = dav_client(dav_response(404, "text/plain", ""))
  assert_false(miss.exists(path="/a.txt"))
}

///|
async test "move_path 携带绝对 Destination 与 Overwrite 头" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.move_path(src="/a.txt", dst="/dir/b.txt")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "MOVE")
  assert_eq(
    request.headers.get("Destination"),
    Some("http://127.0.0.1:8080/dav/dir/b.txt"),
  )
  // 默认覆盖
  assert_eq(request.headers.get("Overwrite"), Some("T"))
  client.move_path(src="/a.txt", dst="/dir/b.txt", overwrite=false)
  let guarded = mock.last_request().unwrap()
  assert_eq(guarded.headers.get("Overwrite"), Some("F"))
}

///|
async test "copy_path 携带 COPY 与 Destination" {
  let (client, mock) = dav_client(dav_response(204, "text/plain", ""))
  client.copy_path(src="/a.txt", dst="/copy.txt")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "COPY")
  assert_eq(
    request.headers.get("Destination"),
    Some("http://127.0.0.1:8080/dav/copy.txt"),
  )
}

///|
async test "move 目标存在且不允许覆盖时抛 Api(412)" {
  let (client, _) = dav_client(dav_response(412, "text/plain", ""))
  let error = capture_error(() => {
    client.move_path(src="/a", dst="/b", overwrite=false)
  }).unwrap()
  assert_true(error.detail() is Api(status=412, operation="MOVE", message=_))
}
