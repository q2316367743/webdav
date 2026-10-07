// 根包黑盒测试：从用户视角（@webdav.xxx）走一遍完整操作流，
// 用 MockTransport::from_responses 按序供响应，不触网。

///|
fn mock_response(
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
async test "门面完整操作流：建目录 → 上传 → 列目录 → 下载 → 属性 → 移动 → 复制 → 删除 → 探测" {
  let list_xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/dav/demo/</D:href>
    #|  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
    #| </D:response>
    #| <D:response>
    #|  <D:href>/dav/demo/hello.txt</D:href>
    #|  <D:propstat><D:prop>
    #|    <D:resourcetype/><D:getcontentlength>12</D:getcontentlength>
    #|  </D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let propfind_xml = "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\" xmlns:X=\"urn:q2316367743:webdav:prop\">" +
    "<D:response><D:href>/dav/demo/hello.txt</D:href>" +
    "<D:propstat><D:prop><X:color>red</X:color></D:prop></D:propstat></D:response></D:multistatus>"
  let propupdate_result = "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/dav/demo/hello.txt</D:href>" +
    "<D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
  let options_response : @transport.RawResponse = {
    status: 204,
    status_text: "",
    headers: @transport.Headers::new()
    .set("Content-Type", "text/plain")
    .set("DAV", "1, 2")
    .set("Allow", "OPTIONS, GET, HEAD, PUT, PROPFIND"),
    set_cookies: [],
    body: @transport.ResponseBody::from_bytes(Bytes::new(0)),
  }
  let mock = @transport.MockTransport::from_responses([
    mock_response(201, "text/plain", ""), // MKCOL /demo
    mock_response(201, "text/plain", ""), // PUT /demo/hello.txt
    mock_response(207, "application/xml; charset=utf-8", list_xml), // PROPFIND Depth:1
    mock_response(200, "text/plain", "hello webdav"), // GET
    mock_response(207, "application/xml; charset=utf-8", propfind_xml), // get_properties
    mock_response(207, "application/xml; charset=utf-8", propupdate_result), // PROPPATCH
    mock_response(201, "text/plain", ""), // MOVE
    mock_response(201, "text/plain", ""), // COPY
    mock_response(204, "text/plain", ""), // DELETE
    options_response, // OPTIONS
  ])
  let transport : &@transport.Transport = mock
  let client = @webdav.create_webdav_client_with_transport(
    {
      base_url: "http://127.0.0.1:8080/dav/",
      username: Some("user"),
      password: Some("pass"),
      timeout_ms: None,
    },
    transport,
  )
  // 建目录 → 上传（带进度）
  client.mkdir(path="/demo")
  let mut uploaded = 0
  let put = client.put_file(
    path="/demo/hello.txt",
    data=@utf8.encode("hello webdav"),
    content_type="text/plain",
    on_progress=fn(progress : @webdav.Progress) { uploaded = progress.loaded },
  )
  assert_eq(put.status, 201)
  assert_true(put.created)
  // 列目录：自身（/demo/）被排除
  let items = client.list(path="/demo")
  assert_eq(items.length(), 1)
  assert_eq(items[0].name, "hello.txt")
  assert_eq(items[0].content_length, Some(12))
  // 下载（全量）：新接口把内容与响应元数据一起回传
  let got = client.get_file(path="/demo/hello.txt")
  assert_eq(got.content, @utf8.encode("hello webdav"))
  assert_eq(got.status, 200)
  assert_eq(got.content_type, Some("text/plain"))
  // 属性读写
  let props = client.get_properties(path="/demo/hello.txt", names=["color"])
  assert_eq(props.get("color"), Some("red"))
  client.set_properties(path="/demo/hello.txt", props=[("color", "blue")])
  // MockTransport 不写真实连接，上传进度保持 0（真实进度见 cmd/main 演示）
  assert_eq(uploaded, 0)
  // 移动 / 复制 / 删除
  client.move_path(src="/demo/hello.txt", dst="/demo/renamed.txt")
  client.copy_path(src="/demo/renamed.txt", dst="/demo/copy.txt")
  client.delete(path="/demo/copy.txt")
  // 能力探测：DAV 等级与 Allow 方法表
  let caps = client.options()
  assert_eq(caps.dav_class, [1, 2])
  assert_true(caps.supports("put"))
  assert_true(caps.has_lock())
  // 全部 10 个请求按序发出（Basic Auth 头也在）
  assert_eq(mock.request_count(), 10)
  assert_eq(mock.received()[1].headers.get("Authorization") is Some(_), true)
}

///|
async test "门面可直接做流式上传与下载到本地路径" {
  let src = @fs.tmpdir(prefix="webdav-facade-") + "/src.bin"
  let payload = @utf8.encode("门面流式往返")
  @fs.write_file(src, payload)
  let reader = @fs.open(src, mode=@fs.Mode::ReadOnly)
  let mock = @transport.MockTransport::from_responses([
    mock_response(201, "text/plain", ""), // put_file_stream
    mock_response(200, "text/plain", "门面流式往返"), // download_to_path
  ])
  let transport : &@transport.Transport = mock
  let client = @webdav.create_webdav_client_with_transport(
    {
      base_url: "http://127.0.0.1:8080/dav/",
      username: None,
      password: None,
      timeout_ms: None,
    },
    transport,
  )
  // 流式上传：调用方给的是读取流，客户端不要求完整 Bytes
  let put = client.put_file_stream(
    path="/stream.bin",
    reader~,
    content_length=payload.length(),
  )
  assert_eq(put.status, 201)
  reader.close()
  // 流式下载到本地路径：写盘由客户端内部完成
  let out = @fs.tmpdir(prefix="webdav-facade-") + "/out.bin"
  client.download_to_path(path="/stream.bin", local_path=out)
  assert_eq(@fs.read_file(out).binary(), payload)
  assert_eq(mock.request_count(), 2)
}

///|
test "门面重导出协议类型与取消信号" {
  assert_eq(@webdav.Depth::Infinity.to_header(), "infinity")
  assert_eq(@webdav.Depth::Zero.to_header(), "0")
  let conditions = @webdav.Conditions::new(if_none_match="*")
  assert_eq(conditions.if_none_match, Some("*"))
  assert_true(conditions.if_match is None)
  let controller = @webdav.AbortController::new()
  assert_false(controller.signal().aborted())
  let caps : @webdav.ServerCapabilities = {
    dav_class: [1, 2],
    allow: ["PROPFIND", "LOCK"],
    server: None,
  }
  assert_true(caps.has_lock())
  let failure : @webdav.ResourceFailure = {
    href: "/dav/a.txt",
    status: 403,
    message: "无权限",
  }
  let error = @webdav.WebdavError::partial(operation="MOVE", failures=[failure])
  assert_true(error.to_string().contains("部分失败"))
  // 本地文件系统错误分支也从门面可用
  let io_error = @webdav.WebdavError::io(message="打开本地文件失败")
  assert_true(io_error.detail() is Io(message=_))
  assert_true(io_error.to_string().contains("本地文件错误"))
}
