// Range 区间下载与断点续传黑盒用例（helper 见 client_test.mbt，
// 基础下载用例见 download_ops_test.mbt）：
// - 请求侧断言 Range / If-Range 头的形状；
// - 响应侧覆盖 206（续传追加）、200（回退重写）、416（已完成 / 报错）
//   与 Content-Range 异常分支。全部经 MockTransport 注入，不触网。

///|
/// 造一份 206 部分内容响应（带 Content-Range 与区间 Content-Length）。
fn partial_response(
  body : String,
  content_range : String,
) -> @transport.RawResponse {
  dav_response_with(206, "text/plain", body, [
    ("Content-Range", content_range),
    ("Content-Length", body.length().to_string()),
  ])
}

///|
async test "get_file 带 range 发 Range 头并解析 206 的 Content-Range" {
  let (client, mock) = dav_client(partial_response("56789", "bytes 5-9/10"))
  let result = client.get_file(
    path="/a.txt",
    range=@types.ByteRange::from(start=5),
  )
  assert_eq(mock.last_request().unwrap().headers.get("Range"), Some("bytes=5-"))
  assert_eq(result.status, 206)
  assert_eq(result.content, @utf8.encode("56789"))
  assert_eq(result.content_length, Some(5))
  let range = result.content_range.unwrap()
  assert_eq(range.first, 5)
  assert_eq(range.last, 9)
  assert_eq(range.total, Some(10))
}

///|
async test "get_file 服务端忽略 Range 回 200 时返回全量" {
  let (client, _) = dav_client(dav_response(200, "text/plain", "0123456789"))
  let result = client.get_file(
    path="/a.txt",
    range=@types.ByteRange::from(start=5),
  )
  assert_eq(result.status, 200)
  assert_eq(result.content, @utf8.encode("0123456789"))
  assert_true(result.content_range is None)
}

///|
async test "get_file 闭区间与后缀区间的 Range 头形状" {
  let (client, mock) = dav_client(partial_response("5678", "bytes 5-8/10"))
  ignore(
    client.get_file(path="/a.txt", range=@types.ByteRange::from(start=5, end=8)),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Range"),
    Some("bytes=5-8"),
  )
  ignore(client.get_file(path="/a.txt", range=@types.ByteRange::suffix(4)))
  assert_eq(mock.last_request().unwrap().headers.get("Range"), Some("bytes=-4"))
}

///|
async test "get_file 416 抛 Api 且消息带区间注解" {
  let (client, _) = dav_client(
    dav_response_with(416, "text/plain", "", [("Content-Range", "bytes */10")]),
  )
  let error = capture_error(() => {
    ignore(
      client.get_file(path="/a.txt", range=@types.ByteRange::from(start=100)),
    )
  }).unwrap()
  assert_true(error.detail() is Api(status=416, operation="GET", message=_))
  assert_true(error.to_string().contains("区间不满足"))
}

///|
async test "download_file 带 range 消费区间内容且进度按区间计" {
  // 区间内容 5 字节，chunk_size=2 → 2/2/1 三块
  let (client, _) = dav_client(partial_response("56789", "bytes 5-9/10"))
  let chunks : Array[Int32] = []
  let progresses : Array[Int32] = []
  client.download_file(
    path="/big.bin",
    on_chunk=fn(chunk) { chunks.push(chunk.length()) },
    chunk_size=2,
    range=@types.ByteRange::from(start=5),
    on_progress=fn(progress : @types.Progress) {
      progresses.push(progress.loaded)
    },
  )
  assert_eq(chunks, [2, 2, 1])
  assert_eq(progresses, [2, 4, 5])
}

///|
async test "download_to_path 带 range 只写区间内容" {
  let (client, _) = dav_client(partial_response("56789", "bytes 5-9/10"))
  let local_path = @fs.tmpdir(prefix="webdav-range-") + "/out.bin"
  client.download_to_path(
    path="/big.bin",
    local_path~,
    range=@types.ByteRange::from(start=5),
  )
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("56789"))
}

///|
async test "resume 本地无文件时全量下载且不发 Range 头" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  let (client, mock) = dav_client(dav_response(200, "text/plain", "0123456789"))
  client.download_to_path_resume(path="/big.bin", local_path~)
  assert_true(mock.last_request().unwrap().headers.get("Range") is None)
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("0123456789"))
}

///|
async test "resume 从本地已有字节续传（206 追加 + If-Range + 绝对进度）" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, mock) = dav_client(partial_response("56789", "bytes 5-9/10"))
  let progresses : Array[Int32] = []
  client.download_to_path_resume(
    path="/big.bin",
    local_path~,
    etag="\"abc\"",
    chunk_size=2,
    on_progress=fn(progress : @types.Progress) {
      progresses.push(progress.loaded)
    },
  )
  let headers = mock.last_request().unwrap().headers
  assert_eq(headers.get("Range"), Some("bytes=5-"))
  assert_eq(headers.get("If-Range"), Some("\"abc\""))
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("0123456789"))
  // 绝对进度：从本地已有 5 字节起累计，总长为资源总长 10
  assert_eq(progresses, [7, 9, 10])
}

///|
async test "resume If-Range 判定资源已变回 200 时截断重写" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, _) = dav_client(
    dav_response(200, "text/plain", "新内容全量"),
  )
  client.download_to_path_resume(path="/big.bin", local_path~, etag="\"old\"")
  // 旧残留不能留下：截断后是完整的新内容
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("新内容全量"))
}

///|
async test "resume 本地已完整时 416 视为成功" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("0123456789"))
  let (client, mock) = dav_client(
    dav_response_with(416, "text/plain", "", [("Content-Range", "bytes */10")]),
  )
  client.download_to_path_resume(path="/big.bin", local_path~)
  assert_eq(
    mock.last_request().unwrap().headers.get("Range"),
    Some("bytes=10-"),
  )
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("0123456789"))
}

///|
async test "resume 416 且本地未下完时抛 Api(416)" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, _) = dav_client(
    dav_response_with(416, "text/plain", "", [("Content-Range", "bytes */10")]),
  )
  let error = capture_error(() => {
    client.download_to_path_resume(path="/big.bin", local_path~)
  }).unwrap()
  assert_true(error.detail() is Api(status=416, operation="GET", message=_))
}

///|
async test "resume 206 区间起点与本地不符时抛 Api" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, _) = dav_client(partial_response("6789", "bytes 6-9/10"))
  let error = capture_error(() => {
    client.download_to_path_resume(path="/big.bin", local_path~)
  }).unwrap()
  assert_true(error.detail() is Api(status=206, operation="GET", message=_))
}

///|
async test "resume 206 缺 Content-Range 时抛 Api" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, _) = dav_client(dav_response(206, "text/plain", "56789"))
  let error = capture_error(() => {
    client.download_to_path_resume(path="/big.bin", local_path~)
  }).unwrap()
  assert_true(error.detail() is Api(status=206, operation="GET", message=_))
}

///|
async test "resume 远端 404 照常抛 Api 且不动本地文件" {
  let local_path = @fs.tmpdir(prefix="webdav-resume-") + "/out.bin"
  @fs.write_file(local_path, @utf8.encode("01234"))
  let (client, _) = dav_client(dav_response(404, "text/plain", ""))
  let error = capture_error(() => {
    client.download_to_path_resume(path="/gone.bin", local_path~)
  }).unwrap()
  assert_true(error.detail() is Api(status=404, operation="GET", message=_))
  assert_eq(@fs.read_file(local_path).binary(), @utf8.encode("01234"))
}

///|
async test "Content-Range 解析：标准、无单位、未知总长与非法形态" {
  let range = @types.parse_content_range("bytes 500-999/3000").unwrap()
  assert_eq(range.first, 500)
  assert_eq(range.last, 999)
  assert_eq(range.total, Some(3000))
  let equaled = @types.parse_content_range("bytes=0-0/1").unwrap()
  assert_eq(equaled.first, 0)
  assert_eq(equaled.total, Some(1))
  let unknown = @types.parse_content_range("bytes 5-9/*").unwrap()
  assert_eq(unknown.last, 9)
  assert_true(unknown.total is None)
  assert_true(@types.parse_content_range("bytes 5-9") is None)
  assert_true(@types.parse_content_range("bytes */10") is None)
  assert_true(@types.parse_content_range("garbage") is None)
  assert_eq(@types.parse_unsatisfied_range_total("bytes */3000"), Some(3000))
  assert_true(@types.parse_unsatisfied_range_total("bytes 0-9/3000") is None)
  assert_true(@types.parse_unsatisfied_range_total("") is None)
}

///|
async test "ByteRange 渲染：闭区间 / 开放端 / 后缀" {
  assert_eq(@types.ByteRange::from(start=5, end=8).header_value(), "bytes=5-8")
  assert_eq(@types.ByteRange::from(start=5).header_value(), "bytes=5-")
  assert_eq(@types.ByteRange::from().header_value(), "bytes=0-")
  assert_eq(@types.ByteRange::suffix(100).header_value(), "bytes=-100")
}
