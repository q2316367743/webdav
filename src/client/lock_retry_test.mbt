// 423 自动重试的黑盒用例：默认关闭、覆盖锁判定（自身 / 深度 infinity 的
// 祖先 / depth 0 不算覆盖）、重试只做一次、可重放的上传才重试、
// 以及释放锁之后注册表不再命中。

///|
/// 造一个开启 423 自动重试的客户端，按队列取响应。
fn retrying_client_queue(
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
        retry_on_423: Some(true),
      },
      transport,
    ),
    mock,
  )
}

///|
async test "默认关闭重试：自己拿着锁也被 423 挡住，一次请求即抛错" {
  let (client, mock) = dav_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  let error = capture_error(() => client.delete(path="/a.txt")).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "开启重试且持有该路径的锁：补上令牌后重试成功" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
    dav_response(204, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  client.delete(path="/a.txt")
  assert_eq(mock.request_count(), 3)
  assert_eq(mock.last_request().unwrap().headers.get("If"), Some("(<tok-1>)"))
}

///|
async test "深度 infinity 的祖先锁覆盖后代路径，重试时用祖先的令牌" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-d>")]),
    dav_response(423, "text/plain", ""),
    dav_response(204, "text/plain", ""),
  ])
  ignore(client.lock(path="/dir", depth=@types.Depth::Infinity))
  client.delete(path="/dir/sub/a.txt")
  assert_eq(mock.request_count(), 3)
  assert_eq(mock.last_request().unwrap().headers.get("If"), Some("(<tok-d>)"))
}

///|
async test "depth 0 的祖先锁不算覆盖，不重试" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-z>")]),
    dav_response(423, "text/plain", ""),
  ])
  ignore(client.lock(path="/dir", depth=@types.Depth::Zero))
  let error = capture_error(() => client.delete(path="/dir/a.txt")).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "没有任何已知锁时 423 直接抛错，不发第二次请求" {
  let (client, mock) = retrying_client_queue([
    dav_response(423, "text/plain", ""),
  ])
  let error = capture_error(() => client.delete(path="/a.txt")).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 1)
}

///|
async test "重试只做一次：仍是 423 就抛错，总请求数为二" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
    dav_response(423, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  let error = capture_error(() => client.delete(path="/a.txt")).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 3)
}

///|
async test "重试时保留原有条件头（If-Match 与令牌共存）" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
    dav_response(204, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  client.delete(
    path="/a.txt",
    conditions=@types.Conditions::new(if_match="\"v1\""),
  )
  let request = mock.last_request().unwrap()
  assert_eq(request.headers.get("If-Match"), Some("\"v1\""))
  assert_eq(request.headers.get("If"), Some("(<tok-1>)"))
}

///|
async test "put_file 的请求体在内存里可重放，423 后重试成功且不串体" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
    dav_response(201, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  let result = client.put_file(path="/a.txt", data=@utf8.encode("hello"))
  assert_eq(result.status, 201)
  assert_eq(mock.request_count(), 3)
  assert_eq(mock.last_request().unwrap().headers.get("If"), Some("(<tok-1>)"))
}

///|
async test "put_file_stream 是一次性流，不参与自动重试" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(423, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  let reader = temp_reader(@utf8.encode("stream"))
  let error = capture_error(() => {
    ignore(client.put_file_stream(path="/a.txt", reader~, content_length=6))
  }).unwrap()
  reader.close()
  guard! error.detail() is Api(status=423, operation="PUT", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "释放锁之后不再自动补令牌：423 直接抛错" {
  let (client, mock) = retrying_client_queue([
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-1>")]),
    dav_response(204, "text/plain", ""),
    dav_response(423, "text/plain", ""),
  ])
  ignore(client.lock(path="/a.txt"))
  client.unlock(path="/a.txt", token="tok-1")
  let error = capture_error(() => client.delete(path="/a.txt")).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
  assert_eq(mock.request_count(), 3)
}
