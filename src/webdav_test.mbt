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
async test "门面完整操作流：建目录 → 上传 → 列目录 → 下载 → 属性 → 移动 → 复制 → 删除" {
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
  client.put_file(
    path="/demo/hello.txt",
    data=@utf8.encode("hello webdav"),
    content_type="text/plain",
    on_progress=fn(progress : @webdav.Progress) { uploaded = progress.loaded },
  )
  // 列目录：自身（/demo/）被排除
  let items = client.list(path="/demo")
  assert_eq(items.length(), 1)
  assert_eq(items[0].name, "hello.txt")
  assert_eq(items[0].content_length, Some(12))
  // 下载（全量）
  let bytes = client.get_file(path="/demo/hello.txt")
  assert_eq(bytes, @utf8.encode("hello webdav"))
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
  // 全部 9 个请求按序发出（Basic Auth 头也在）
  assert_eq(mock.request_count(), 9)
  let put = mock.received()[1]
  assert_eq(put.headers.get("Authorization") is Some(_), true)
}
