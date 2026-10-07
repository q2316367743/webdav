// 下载黑盒用例（全量到内存 / 同步分块回调 / 流式写本地文件）；
// helper 见 client_test.mbt，上传用例见 file_ops_test.mbt。

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

///|
async test "download_to_path 分块写入本地文件并累计进度" {
  // 10 字节，chunk_size=4 → 4/4/2 三块，进度 4/8/10
  let (client, _) = dav_client(dav_response(200, "text/plain", "0123456789"))
  let dir = @fs.tmpdir(prefix="webdav-get-")
  let local_path = dir + "/out.bin"
  let progresses : Array[Int] = []
  client.download_to_path(path="/big.bin", local_path~, chunk_size=4, on_progress=fn(
    progress : @types.Progress,
  ) {
    progresses.push(progress.loaded)
  })
  assert_eq(progresses, [4, 8, 10])
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("0123456789"))
}

///|
async test "download_to_path 覆盖已存在的本地文件" {
  let dir = @fs.tmpdir(prefix="webdav-get-")
  let local_path = dir + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("旧内容比新内容长得多"))
  let (client, _) = dav_client(dav_response(200, "text/plain", "new"))
  client.download_to_path(path="/a.bin", local_path~)
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("new"))
}

///|
async test "download_to_path 404 抛 Api 且不创建本地文件" {
  let dir = @fs.tmpdir(prefix="webdav-get-")
  let local_path = dir + "/missing.bin"
  let (client, _) = dav_client(dav_response(404, "text/plain", ""))
  let error = capture_error(() => {
    client.download_to_path(path="/gone.bin", local_path~)
  }).unwrap()
  assert_true(error.detail() is Api(status=404, operation="GET", message=_))
  // 先请求后建文件：失败不会平白多出一个空文件
  assert_false(@fs.exists(local_path))
}

///|
async test "download_to_path 本地目录不存在时抛 Io" {
  let dir = @fs.tmpdir(prefix="webdav-get-")
  let (client, _) = dav_client(dav_response(200, "text/plain", "x"))
  let error = capture_error(() => {
    client.download_to_path(
      path="/a.bin",
      local_path=dir + "/no-such-dir/out.bin",
    )
  }).unwrap()
  assert_true(error.detail() is Io(message=_))
  assert_true(error.to_string().contains("创建本地文件失败"))
}
