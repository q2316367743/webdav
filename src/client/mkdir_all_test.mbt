// 递归建目录（mkdir_all）黑盒用例：逐级顺序、已存在（405 / 409）跳过、
// 路径切分边界与错误透传；helper 见 client_test.mbt、multistatus_response 见
// dir_ops_test.mbt（同包黑盒测试共用一个作用域）。

///|
/// 可解析的最小 207 响应体：用于 mkdir_all 在 409 后的存在性复核。
fn exists_multistatus() -> @transport.RawResponse {
  multistatus_response(
    "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/dav/a</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>",
  )
}

///|
async test "mkdir_all 自顶向下逐级 MKCOL 并折叠重复斜杠" {
  let (client, mock) = dav_client_queue([
    dav_response(201, "text/plain", ""),
    dav_response(201, "text/plain", ""),
  ])
  // 不以 / 开头、含重复斜杠与结尾斜杠：都应被归一
  client.mkdir_all(path="相册//2024/")
  let requests = mock.received()
  assert_eq(requests.length(), 2)
  assert_eq(requests[0].http_method.to_string(), "MKCOL")
  assert_eq(requests[0].url, "http://127.0.0.1:8080/dav/%E7%9B%B8%E5%86%8C")
  assert_eq(requests[1].http_method.to_string(), "MKCOL")
  assert_eq(
    requests[1].url,
    "http://127.0.0.1:8080/dav/%E7%9B%B8%E5%86%8C/2024",
  )
}

///|
async test "mkdir_all 中间层已存在（405）时跳过并继续建子目录" {
  let (client, mock) = dav_client_queue([
    dav_response(405, "text/plain", ""),
    dav_response(201, "text/plain", ""),
  ])
  client.mkdir_all(path="/exist/new")
  let requests = mock.received()
  assert_eq(requests.length(), 2)
  assert_eq(requests[0].url, "http://127.0.0.1:8080/dav/exist")
  assert_eq(requests[1].url, "http://127.0.0.1:8080/dav/exist/new")
}

///|
async test "mkdir_all 末级已存在（405）视为成功（幂等）" {
  let (client, mock) = dav_client(dav_response(405, "text/plain", ""))
  client.mkdir_all(path="/exist")
  assert_eq(mock.request_count(), 1)
}

///|
async test "mkdir_all 409 且复核不存在时抛原 409，不假装成功" {
  let (client, mock) = dav_client_queue([
    dav_response(409, "text/plain", ""),
    dav_response(404, "text/plain", ""),
  ])
  let error = capture_error(() => client.mkdir_all(path="/a/b")).unwrap()
  assert_true(error.detail() is Api(status=409, operation="MKCOL", message=_))
  // 第一个 409 后做了一次 PROPFIND 复核，随后中止（不再尝试下一级）
  let requests = mock.received()
  assert_eq(requests.length(), 2)
  assert_eq(requests[1].http_method.to_string(), "PROPFIND")
  assert_eq(requests[1].headers.get("Depth"), Some("0"))
}

///|
async test "mkdir_all 409 但复核已存在（并发创建）时跳过并继续" {
  let (client, mock) = dav_client_queue([
    dav_response(409, "text/plain", ""),
    exists_multistatus(),
    dav_response(201, "text/plain", ""),
  ])
  client.mkdir_all(path="/a/b")
  let requests = mock.received()
  assert_eq(requests.length(), 3)
  assert_eq(requests[0].http_method.to_string(), "MKCOL")
  assert_eq(requests[1].http_method.to_string(), "PROPFIND")
  assert_eq(requests[2].http_method.to_string(), "MKCOL")
  assert_eq(requests[2].url, "http://127.0.0.1:8080/dav/a/b")
}

///|
async test "mkdir_all 挂载点自身（/ 与空串）不发请求" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir_all(path="/")
  client.mkdir_all(path="")
  assert_eq(mock.request_count(), 0)
}

///|
async test "mkdir_all 其他状态码（403）原样抛出且不做存在性复核" {
  let (client, mock) = dav_client(dav_response(403, "text/plain", ""))
  let error = capture_error(() => client.mkdir_all(path="/a/b")).unwrap()
  assert_true(error.detail() is Api(status=403, operation="MKCOL", message=_))
  assert_eq(mock.request_count(), 1)
}

///|
async test "mkdir_all 中途失败保留原错误（已建层级不回滚）" {
  let (client, mock) = dav_client_queue([
    dav_response(201, "text/plain", ""),
    dav_response(403, "text/plain", ""),
  ])
  let error = capture_error(() => client.mkdir_all(path="/a/b")).unwrap()
  assert_true(error.detail() is Api(status=403, operation="MKCOL", message=_))
  let requests = mock.received()
  assert_eq(requests.length(), 2)
  assert_eq(requests[1].url, "http://127.0.0.1:8080/dav/a/b")
}

///|
async test "mkdir_all 把 conditions 逐级落到 If 头" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir_all(
    path="/a",
    conditions=@types.Conditions::new(lock_token="tok-1"),
  )
  assert_eq(mock.last_request().unwrap().headers.get("If"), Some("(<tok-1>)"))
}
