// 共享锁的黑盒用例：请求体里的 `lockscope`、响应缺 `lockscope` 时的
// 作用域回填，以及服务端回传值优先于请求值（RFC 4918 §9.10 / §14.11）。

///|
async test "共享锁请求体生成 <D:shared/>，响应缺 lockscope 时按请求作用域回填" {
  let (client, mock) = dav_client(
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-s>")]),
  )
  let result = client.lock(path="/a.txt", scope=@types.LockScope::Shared)
  let expected = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:lockinfo xmlns:D=\"DAV:\">" +
    "<D:lockscope><D:shared/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "</D:lockinfo>"
  assert_true(
    mock.last_request().unwrap().body
    is Some(@transport.RequestBody::Buffered(bytes)) &&
    bytes == @utf8.encode(expected),
  )
  assert_true(result.lock.scope is @types.LockScope::Shared)
}

///|
async test "省略 scope 时仍发独占写锁体并按独占回填" {
  let (client, mock) = dav_client(
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-e>")]),
  )
  let result = client.lock(path="/a.txt")
  let expected = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:lockinfo xmlns:D=\"DAV:\">" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "</D:lockinfo>"
  assert_true(
    mock.last_request().unwrap().body
    is Some(@transport.RequestBody::Buffered(bytes)) &&
    bytes == @utf8.encode(expected),
  )
  assert_true(result.lock.scope is @types.LockScope::Exclusive)
}

///|
async test "服务端回传的 lockscope 优先于请求时的作用域" {
  let body = "<?xml version=\"1.0\"?>" +
    "<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:locktoken><D:href>opaquelocktoken:t9</D:href></D:locktoken>" +
    "</D:activelock></D:lockdiscovery></D:prop>"
  let (client, _) = dav_client(
    dav_response_with(200, "application/xml", body, [("Lock-Token", "<t9>")]),
  )
  let result = client.lock(path="/a.txt", scope=@types.LockScope::Shared)
  assert_true(result.lock.scope is @types.LockScope::Exclusive)
}

///|
async test "服务端回传 shared、请求独占时以服务端为准" {
  let body = "<?xml version=\"1.0\"?>" +
    "<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>" +
    "<D:lockscope><D:shared/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:locktoken><D:href>opaquelocktoken:t7</D:href></D:locktoken>" +
    "</D:activelock></D:lockdiscovery></D:prop>"
  let (client, _) = dav_client(dav_response(200, "application/xml", body))
  let result = client.lock(path="/a.txt")
  assert_eq(result.lock.token, "opaquelocktoken:t7")
  assert_true(result.lock.scope is @types.LockScope::Shared)
}

///|
async test "刷新锁的响应缺 lockscope 时按独占回填（刷新不带作用域参数）" {
  let (client, _) = dav_client(
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<tok-r>")]),
  )
  let result = client.refresh_lock(path="/a.txt", token="tok-r")
  assert_true(result.lock.scope is @types.LockScope::Exclusive)
}
