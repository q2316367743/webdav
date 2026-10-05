// 目录 / 属性操作的黑盒用例；helper 见 client_test.mbt。

///|
fn multistatus_response(body : String) -> @transport.RawResponse {
  dav_response(207, "application/xml; charset=utf-8", body)
}

///|
async test "list 解析 Depth:1 响应并排除目录自身" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/dav/</D:href>
    #|  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
    #| </D:response>
    #| <D:response>
    #|  <D:href>/dav/dir/</D:href>
    #|  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
    #| </D:response>
    #| <D:response>
    #|  <D:href>/dav/a.txt</D:href>
    #|  <D:propstat><D:prop>
    #|    <D:resourcetype/><D:getcontentlength>5</D:getcontentlength>
    #|  </D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let (client, mock) = dav_client(multistatus_response(xml))
  let items = client.list(path="/")
  // 自身（/dav/）被排除，剩一个目录一个文件
  assert_eq(items.length(), 2)
  assert_true(items[0].is_dir)
  assert_eq(items[0].name, "dir")
  assert_false(items[1].is_dir)
  assert_eq(items[1].name, "a.txt")
  assert_eq(items[1].content_length, Some(5))
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PROPFIND")
  assert_eq(request.headers.get("Depth"), Some("1"))
}

///|
async test "stat 解析 Depth:0 单条响应" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/dav/a.txt</D:href>
    #|  <D:propstat><D:prop>
    #|    <D:resourcetype/><D:getcontenttype>text/plain</D:getcontenttype>
    #|    <D:getetag>"xyz"</D:getetag>
    #|  </D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let (client, mock) = dav_client(multistatus_response(xml))
  let info = client.stat(path="/a.txt")
  assert_false(info.is_dir)
  assert_eq(info.name, "a.txt")
  assert_eq(info.content_type, Some("text/plain"))
  assert_eq(info.etag, Some("\"xyz\""))
  assert_eq(mock.last_request().unwrap().headers.get("Depth"), Some("0"))
}

///|
async test "list 不存在的路径抛 Api(404)" {
  let (client, _) = dav_client(dav_response(404, "text/plain", ""))
  let error = capture_error(() => ignore(client.list(path="/missing"))).unwrap()
  assert_true(
    error.detail() is Api(status=404, operation="PROPFIND", message=_),
  )
}

///|
async test "set_properties 发出 PROPPATCH 与属性请求体" {
  let (client, mock) = dav_client(
    multistatus_response(
      "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/dav/a.txt</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>",
    ),
  )
  client.set_properties(path="/a.txt", props=[("color", "red")])
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PROPPATCH")
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/xml; charset=utf-8"),
  )
  let expected = "<D:propertyupdate xmlns:D=\"DAV:\" xmlns:X=\"urn:q2316367743:webdav:prop\">" +
    "<D:set><D:prop><X:color>red</X:color></D:prop></D:set></D:propertyupdate>"
  assert_eq(request.body, Some(@utf8.encode(expected)))
}

///|
async test "set_properties 非法属性名抛 Api(400)" {
  let (client, _) = dav_client(dav_response(207, "application/xml", ""))
  let error = capture_error(() => {
    client.set_properties(path="/a", props=[("bad name!", "x")])
  }).unwrap()
  assert_true(
    error.detail() is Api(status=400, operation="PROPPATCH", message=_),
  )
}

///|
async test "get_properties 返回命名空间内的属性映射" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:" xmlns:X="urn:q2316367743:webdav:prop">
    #| <D:response>
    #|  <D:href>/dav/a.txt</D:href>
    #|  <D:propstat><D:prop>
    #|    <X:color>red</X:color><X:note>备注</X:note>
    #|  </D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let (client, _) = dav_client(multistatus_response(xml))
  let props = client.get_properties(path="/a.txt", names=[
    "color", "note", "absent",
  ])
  assert_eq(props.get("color"), Some("red"))
  assert_eq(props.get("note"), Some("备注"))
  assert_true(props.get("absent") is None)
}
