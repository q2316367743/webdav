// 上传 / 下载 / 流式 / 进度 / 条件请求的黑盒用例；helper 见 client_test.mbt。

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
async test "get_file 返回内容与响应元数据并触发下载进度" {
  let (client, _) = dav_client(
    dav_response_with(200, "text/plain", "hello webdav", [
      ("Content-Length", "12"),
      ("ETag", "\"abc\""),
      ("Last-Modified", "Wed, 01 Oct 2025 00:00:00 GMT"),
    ]),
  )
  let mut last : @types.Progress? = None
  let result = client.get_file(path="/a.txt", on_progress=fn(
    progress : @types.Progress,
  ) {
    last = Some(progress)
  })
  assert_eq(result.content, @utf8.encode("hello webdav"))
  assert_eq(result.status, 200)
  assert_eq(result.content_type, Some("text/plain"))
  assert_eq(result.content_length, Some(12))
  assert_eq(result.etag, Some("\"abc\""))
  assert_eq(result.last_modified, Some("Wed, 01 Oct 2025 00:00:00 GMT"))
  let progress = last.unwrap()
  assert_eq(progress.loaded, 12)
  assert_eq(progress.total, Some(12))
}

///|
async test "get_file 条件请求写 If-Match 头" {
  let (client, mock) = dav_client(dav_response(200, "text/plain", "ok"))
  ignore(
    client.get_file(
      path="/a.txt",
      conditions=@types.Conditions::new(if_match="\"abc\""),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If-Match"),
    Some("\"abc\""),
  )
}

///|
async test "download_file 分块消费并累计进度" {
  // 10 字节，chunk_size=4 → 4/4/2 三块，进度 4/8/10
  let (client, _) = dav_client(dav_response(200, "text/plain", "0123456789"))
  let chunks : Array[Int] = []
  let progresses : Array[Int] = []
  client.download_file(
    path="/big.bin",
    on_chunk=fn(chunk : Bytes) { chunks.push(chunk.length()) },
    chunk_size=4,
    on_progress=fn(progress : @types.Progress) {
      progresses.push(progress.loaded)
    },
  )
  assert_eq(chunks, [4, 4, 2])
  assert_eq(progresses, [4, 8, 10])
}

///|
async test "download_file 404 抛 Api" {
  let (client, _) = dav_client(dav_response(404, "text/plain", ""))
  let error = capture_error(() => {
    client.download_file(path="/gone.bin", on_chunk=fn(_) { () })
  }).unwrap()
  assert_true(error.detail() is Api(status=404, operation="GET", message=_))
}
