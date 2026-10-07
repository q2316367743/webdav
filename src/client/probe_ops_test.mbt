// 能力探测（OPTIONS）与存在性（HEAD → PROPFIND 回退）的黑盒用例；
// helper 见 client_test.mbt。

///|
async test "options 解析 DAV / Allow / Server" {
  let (client, mock) = dav_client(
    dav_response_with(204, "", "", [
      ("DAV", "1, 2, extended-mkcol"),
      ("Allow", "OPTIONS, GET, HEAD, PROPFIND, LOCK"),
      ("Server", "TestDAV/1.0"),
    ]),
  )
  let caps = client.options()
  assert_eq(caps.dav_class, [1, 2])
  assert_eq(caps.allow, ["OPTIONS", "GET", "HEAD", "PROPFIND", "LOCK"])
  assert_true(caps.supports("propfind"))
  assert_false(caps.supports("report"))
  assert_true(caps.has_lock())
  assert_eq(caps.server, Some("TestDAV/1.0"))
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "OPTIONS")
  assert_eq(request.url, "http://127.0.0.1:8080/dav/")
}

///|
async test "options 无 DAV 头时按 Class 1，无 LOCK 则 has_lock 为假" {
  let (client, mock) = dav_client(
    dav_response_with(200, "", "", [("Allow", "OPTIONS, GET")]),
  )
  let caps = client.options(path="/dir")
  assert_eq(caps.dav_class, [1])
  assert_false(caps.has_lock())
  assert_eq(caps.server, None)
  assert_eq(mock.last_request().unwrap().url, "http://127.0.0.1:8080/dav/dir")
}

///|
async test "exists 在 HEAD 405 时回落到 PROPFIND Depth:0" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/dav/a.txt</D:href>
    #|  <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let (client, mock) = dav_client_queue([
    dav_response(405, "text/plain", ""),
    multistatus_response(xml),
  ])
  assert_true(client.exists(path="/a.txt"))
  let requests = mock.received()
  assert_eq(requests.length(), 2)
  assert_eq(requests[0].http_method.to_string(), "HEAD")
  assert_eq(requests[1].http_method.to_string(), "PROPFIND")
  assert_eq(requests[1].headers.get("Depth"), Some("0"))
}

///|
async test "exists 在 HEAD 501 且 PROPFIND 404 时为假" {
  let (client, _) = dav_client_queue([
    dav_response(501, "text/plain", ""),
    dav_response(404, "text/plain", ""),
  ])
  assert_false(client.exists(path="/gone.txt"))
}

///|
async test "exists 对 HEAD 304 视为存在（条件命中）" {
  let (client, mock) = dav_client(dav_response(304, "text/plain", ""))
  assert_true(
    client.exists(
      path="/a.txt",
      conditions=@types.Conditions::new(if_none_match="\"v1\""),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If-None-Match"),
    Some("\"v1\""),
  )
}
