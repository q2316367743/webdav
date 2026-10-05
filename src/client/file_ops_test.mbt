// 上传 / 下载 / 流式 / 进度的黑盒用例；helper 见 client_test.mbt。

///|
async test "put_file 原样发送二进制请求体与 Content-Type" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let payload = @utf8.encode("你好，WebDAV！\u{00FF}\u{0000}")
  client.put_file(
    path="/中文 file.bin",
    data=payload,
    content_type="application/octet-stream",
  )
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PUT")
  assert_eq(
    request.url,
    "http://127.0.0.1:8080/dav/%E4%B8%AD%E6%96%87%20file.bin",
  )
  assert_eq(request.body, Some(payload))
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/octet-stream"),
  )
}

///|
async test "put_file 非期望状态码抛 Api" {
  let (client, _) = dav_client(dav_response(409, "text/plain", ""))
  let error = capture_error(() => {
    client.put_file(path="/no-parent/a", data=@utf8.encode("x"))
  }).unwrap()
  assert_true(error.detail() is Api(status=409, operation="PUT", message=_))
}

///|
async test "get_file 返回响应体并触发下载进度" {
  let (client, _) = dav_client(dav_response(200, "text/plain", "hello webdav"))
  let mut last : @types.Progress? = None
  let bytes = client.get_file(path="/a.txt", on_progress=fn(
    progress : @types.Progress,
  ) {
    last = Some(progress)
  })
  assert_eq(bytes, @utf8.encode("hello webdav"))
  let progress = last.unwrap()
  assert_eq(progress.loaded, 12)
  assert_eq(progress.total, Some(12))
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
