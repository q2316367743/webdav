// 上传黑盒用例（三种形态：Bytes / 读取流 / 本地文件路径）；
// helper 见 client_test.mbt，下载用例见 download_ops_test.mbt。

///|
async test "put_file 原样发送二进制请求体与 Content-Type" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let payload = @utf8.encode("你好，WebDAV！\u{00FF}\u{0000}")
  let result = client.put_file(
    path="/中文 file.bin",
    data=payload,
    content_type="application/octet-stream",
  )
  assert_eq(result.status, 201)
  assert_true(result.created)
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PUT")
  assert_eq(
    request.url,
    "http://127.0.0.1:8080/dav/%E4%B8%AD%E6%96%87%20file.bin",
  )
  // Mock 记录流式请求体的引用而不消费：读回验证声明长度与内容
  guard! request.body is Some(@transport.RequestBody::Stream(body))
  assert_eq(body.content_length, Some(payload.length()))
  assert_eq(body.reader.read_all().binary(), payload)
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/octet-stream"),
  )
}

///|
async test "put_file 回传 ETag / Last-Modified / Location" {
  let (client, _) = dav_client(
    dav_response_with(200, "text/plain", "", [
      ("ETag", "\"v1\""),
      ("Last-Modified", "Wed, 01 Oct 2025 00:00:00 GMT"),
      ("Location", "http://127.0.0.1:8080/dav/new.txt"),
    ]),
  )
  let result = client.put_file(path="/new.txt", data=@utf8.encode("x"))
  assert_eq(result.status, 200)
  assert_false(result.created)
  assert_eq(result.etag, Some("\"v1\""))
  assert_eq(result.last_modified, Some("Wed, 01 Oct 2025 00:00:00 GMT"))
  assert_eq(result.location, Some("http://127.0.0.1:8080/dav/new.txt"))
}

///|
async test "put_file 条件请求写 If-None-Match 头" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  ignore(
    client.put_file(
      path="/only-new.txt",
      data=@utf8.encode("x"),
      conditions=@types.Conditions::new(if_none_match="*"),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If-None-Match"),
    Some("*"),
  )
}

///|
async test "put_file 非期望状态码抛 Api" {
  let (client, _) = dav_client(dav_response(409, "text/plain", "no parent"))
  let error = capture_error(() => {
    ignore(client.put_file(path="/no-parent/a", data=@utf8.encode("x")))
  }).unwrap()
  let detail = error.detail()
  assert_true(detail is Api(status=409, operation="PUT", message=_))
  // 失败消息带上响应体摘要，便于定位服务端原因
  assert_true(error.to_string().contains("no parent"))
}

///|
async test "put_file_stream 声明长度时定长分帧并原样发送流内容" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let payload = @utf8.encode(
    "流式上传：边读边发，不整份驻留内存",
  )
  let reader = temp_reader(payload)
  let result = client.put_file_stream(
    path="/stream.bin",
    reader~,
    content_length=payload.length(),
    content_type="application/octet-stream",
    conditions=@types.Conditions::new(if_none_match="*"),
  )
  assert_eq(result.status, 201)
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PUT")
  assert_eq(request.url, "http://127.0.0.1:8080/dav/stream.bin")
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/octet-stream"),
  )
  assert_eq(request.headers.get("If-None-Match"), Some("*"))
  guard! request.body is Some(@transport.RequestBody::Stream(body))
  assert_eq(body.content_length, Some(payload.length()))
  assert_eq(body.reader.read_all().binary(), payload)
  reader.close()
}

///|
async test "put_file_stream 不给长度时分帧交给传输层（长度未知）" {
  let (client, mock) = dav_client(dav_response(200, "text/plain", ""))
  let reader = temp_reader(@utf8.encode("chunked"))
  ignore(client.put_file_stream(path="/chunked.bin", reader~))
  guard! mock.last_request().unwrap().body
    is Some(@transport.RequestBody::Stream(body))
  // None → 传输层按 chunked 分帧，上传进度 total 也为 None
  assert_eq(body.content_length, None)
  reader.close()
}

///|
async test "put_file_stream 非期望状态码抛 Api" {
  let (client, _) = dav_client(dav_response(507, "text/plain", "quota"))
  let reader = temp_reader(@utf8.encode("x"))
  let error = capture_error(() => {
    ignore(client.put_file_stream(path="/full.bin", reader~))
  }).unwrap()
  assert_true(error.detail() is Api(status=507, operation="PUT", message=_))
  reader.close()
}

///|
async test "put_file_from_path 用本地文件长度定长上传" {
  let dir = @fs.tmpdir(prefix="webdav-put-")
  let local_path = dir + "/payload.bin"
  let payload = @utf8.encode("本地文件形态：内容不整份读进内存")
  @fs.write_file(local_path, payload)
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let result = client.put_file_from_path(
    path="/from-path.bin",
    local_path~,
    content_type="application/octet-stream",
  )
  assert_eq(result.status, 201)
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PUT")
  assert_eq(request.url, "http://127.0.0.1:8080/dav/from-path.bin")
  guard! request.body is Some(@transport.RequestBody::Stream(body))
  assert_eq(body.content_length, Some(payload.length()))
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/octet-stream"),
  )
}

///|
async test "put_file_from_path 本地文件不存在抛 Io 且不发请求" {
  let dir = @fs.tmpdir(prefix="webdav-put-")
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    ignore(
      client.put_file_from_path(
        path="/gone.bin",
        local_path=dir + "/not-there.bin",
      ),
    )
  }).unwrap()
  assert_true(error.detail() is Io(message=_))
  assert_true(error.to_string().contains("打开本地文件失败"))
  // 本地问题在发请求之前就暴露：Mock 上没有留下任何请求
  assert_true(mock.last_request() is None)
}

///|
async test "put_file_from_path 路径是目录时抛 Io" {
  let dir = @fs.tmpdir(prefix="webdav-put-")
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    ignore(client.put_file_from_path(path="/dir.bin", local_path=dir))
  }).unwrap()
  assert_true(error.detail() is Io(message=_))
  assert_true(error.to_string().contains("是目录"))
  assert_true(mock.last_request() is None)
}
