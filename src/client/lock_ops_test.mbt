// 锁操作的黑盒用例：LOCK / 刷新 / UNLOCK / 锁发现的请求形状、
// 令牌来源优先级与错误分支，全部经 MockTransport 注入，不触网。

///|
async test "lock 发独占写锁体并解析 Lock-Token 响应头" {
  let (client, mock) = dav_client(
    dav_response_with(200, "application/xml", "", [
      ("Lock-Token", "<1791426373>"),
    ]),
  )
  let result = client.lock(
    path="/a.txt",
    owner="demo@example.com",
    timeout="Second-300",
  )
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "LOCK")
  assert_eq(request.url, "http://127.0.0.1:8080/dav/a.txt")
  assert_eq(request.headers.get("Timeout"), Some("Second-300"))
  assert_eq(request.headers.get("Depth"), None)
  assert_eq(
    request.headers.get("Content-Type"),
    Some("application/xml; charset=utf-8"),
  )
  let expected = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:lockinfo xmlns:D=\"DAV:\">" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:owner>demo@example.com</D:owner>" +
    "</D:lockinfo>"
  assert_true(
    request.body is Some(@transport.RequestBody::Buffered(bytes)) &&
    bytes == @utf8.encode(expected),
  )
  assert_eq(result.status, 200)
  assert_false(result.created)
  assert_eq(result.lock.token, "1791426373")
  assert_eq(result.lock.scope, "exclusive")
}

///|
async test "lock 的 201 表示创建了 lock-null 资源" {
  let (client, _) = dav_client(
    dav_response_with(201, "application/xml", "", [("Lock-Token", "<tok-201>")]),
  )
  let result = client.lock(path="/new.txt")
  assert_eq(result.status, 201)
  assert_true(result.created)
  assert_eq(result.lock.token, "tok-201")
}

///|
async test "lock 没有 Lock-Token 头时从响应体取令牌与元数据" {
  let body = "<?xml version=\"1.0\"?>" +
    "<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:depth>infinity</D:depth>" +
    "<D:owner>张三</D:owner>" +
    "<D:timeout>Second-3600</D:timeout>" +
    "<D:locktoken><D:href>opaquelocktoken:t1</D:href></D:locktoken>" +
    "<D:lockroot><D:href>/dav/a.txt</D:href></D:lockroot>" +
    "</D:activelock></D:lockdiscovery></D:prop>"
  let (client, _) = dav_client(
    dav_response(200, "application/xml; charset=utf-8", body),
  )
  let result = client.lock(path="/a.txt")
  assert_eq(result.lock.token, "opaquelocktoken:t1")
  assert_eq(result.lock.depth, Some("infinity"))
  assert_eq(result.lock.owner, Some("张三"))
  assert_eq(result.lock.timeout, Some("Second-3600"))
  assert_eq(result.lock.lockroot, Some("/dav/a.txt"))
}

///|
async test "lock 头与体都有令牌时以响应头为准" {
  let body = "<D:lockdiscovery xmlns:D=\"DAV:\"><D:activelock>" +
    "<D:locktoken><D:href>body-token</D:href></D:locktoken>" +
    "<D:timeout>Second-60</D:timeout>" +
    "</D:activelock></D:lockdiscovery>"
  let (client, _) = dav_client(
    dav_response_with(200, "application/xml", body, [
      ("Lock-Token", "<header-token>"),
    ]),
  )
  let result = client.lock(path="/a.txt")
  assert_eq(result.lock.token, "header-token")
  // 元数据仍来自响应体
  assert_eq(result.lock.timeout, Some("Second-60"))
}

///|
async test "lock 响应既无令牌头也无 lockdiscovery 时抛 Api" {
  // <x/> 合法但不属于 DAV: 命名空间，锁发现为空
  let (client, _) = dav_client(dav_response(200, "application/xml", "<x/>"))
  let error = capture_error(() => ignore(client.lock(path="/a.txt"))).unwrap()
  guard! error.detail() is Api(status=200, operation="LOCK", message~)
  assert_true(message.contains("响应缺少锁令牌"))
}

///|
async test "lock 响应体非法但有 Lock-Token 头时仍成功" {
  let (client, _) = dav_client(
    dav_response_with(200, "application/xml", "<D:lockdiscovery 坏了", [
      ("Lock-Token", "<tok-x>"),
    ]),
  )
  let result = client.lock(path="/a.txt")
  assert_eq(result.lock.token, "tok-x")
  assert_eq(result.lock.timeout, None)
}

///|
async test "lock 响应体非法且无令牌头时抛 Xml" {
  let (client, _) = dav_client(
    dav_response(200, "application/xml", "<D:lockdiscovery 坏了"),
  )
  let error = capture_error(() => ignore(client.lock(path="/a.txt"))).unwrap()
  assert_true(error.detail() is Xml(_))
}

///|
async test "lock 的 Depth::One 在本地拦下，不发请求" {
  let (client, mock) = dav_client(dav_response(200, "application/xml", ""))
  let error = capture_error(() => {
    ignore(client.lock(path="/a.txt", depth=@types.Depth::One))
  }).unwrap()
  guard! error.detail() is Api(status=400, operation="LOCK", message~)
  assert_true(message.contains("Depth"))
  assert_eq(mock.request_count(), 0)
}

///|
async test "lock 发 Depth 头（Zero / Infinity）" {
  let (zero, zero_mock) = dav_client(
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<t>")]),
  )
  ignore(zero.lock(path="/a.txt", depth=@types.Depth::Zero))
  assert_eq(zero_mock.last_request().unwrap().headers.get("Depth"), Some("0"))
  let (inf, inf_mock) = dav_client(
    dav_response_with(200, "application/xml", "", [("Lock-Token", "<t>")]),
  )
  ignore(inf.lock(path="/a.txt", depth=@types.Depth::Infinity))
  assert_eq(
    inf_mock.last_request().unwrap().headers.get("Depth"),
    Some("infinity"),
  )
}

///|
async test "refresh_lock 无请求体，带 If 与 Timeout，令牌沿用传入值" {
  let (client, mock) = dav_client(
    dav_response(200, "application/xml; charset=utf-8", ""),
  )
  let result = client.refresh_lock(
    path="/a.txt",
    token="opaquelocktoken:t1",
    timeout="Second-600",
  )
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "LOCK")
  assert_eq(request.headers.get("If"), Some("(<opaquelocktoken:t1>)"))
  assert_eq(request.headers.get("Timeout"), Some("Second-600"))
  assert_eq(request.headers.get("Content-Type"), None)
  assert_true(request.body is None)
  assert_eq(result.status, 200)
  assert_false(result.created)
  assert_eq(result.lock.token, "opaquelocktoken:t1")
}

///|
async test "refresh_lock 空令牌在本地拦下" {
  let (client, mock) = dav_client(dav_response(200, "application/xml", ""))
  let error = capture_error(() => {
    ignore(client.refresh_lock(path="/a.txt", token="  "))
  }).unwrap()
  assert_true(
    error.detail()
    is Api(status=400, operation="LOCK", message="锁令牌不能为空"),
  )
  assert_eq(mock.request_count(), 0)
}

///|
async test "unlock 把令牌归一成 Lock-Token: <令牌>" {
  let (client, mock) = dav_client(dav_response(204, "text/plain", ""))
  client.unlock(path="/a.txt", token="<abc>")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "UNLOCK")
  // 传入的令牌自带尖括号时不会变成 <<abc>>
  assert_eq(request.headers.get("Lock-Token"), Some("<abc>"))
  client.unlock(path="/a.txt", token=" abc ")
  assert_eq(
    mock.last_request().unwrap().headers.get("Lock-Token"),
    Some("<abc>"),
  )
}

///|
async test "unlock 令牌不匹配时抛 Api(409)" {
  let (client, _) = dav_client(dav_response(409, "text/plain", ""))
  let error = capture_error(() => client.unlock(path="/a.txt", token="bad")).unwrap()
  guard! error.detail() is Api(status=409, operation="UNLOCK", message~)
  assert_true(message.contains("冲突"))
}

///|
async test "get_locks 用 Depth 0 的 PROPFIND 读 lockdiscovery" {
  let body = "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">" +
    "<D:response><D:href>/dav/a.txt</D:href><D:propstat><D:prop>" +
    "<D:lockdiscovery><D:activelock>" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:timeout>Second-600</D:timeout>" +
    "<D:locktoken><D:href>opaquelocktoken:t1</D:href></D:locktoken>" +
    "<D:lockroot><D:href>/dav/a.txt</D:href></D:lockroot>" +
    "</D:activelock></D:lockdiscovery>" +
    "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>" +
    "</D:response></D:multistatus>"
  let (client, mock) = dav_client(
    dav_response(207, "application/xml; charset=utf-8", body),
  )
  let locks = client.get_locks(path="/a.txt")
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "PROPFIND")
  assert_eq(request.headers.get("Depth"), Some("0"))
  let expected = "<D:propfind xmlns:D=\"DAV:\" xmlns:X=\"DAV:\">" +
    "<D:prop><X:lockdiscovery/></D:prop></D:propfind>"
  assert_true(
    request.body is Some(@transport.RequestBody::Buffered(bytes)) &&
    bytes == @utf8.encode(expected),
  )
  assert_eq(locks.length(), 1)
  assert_eq(locks[0].token, "opaquelocktoken:t1")
  assert_eq(locks[0].timeout, Some("Second-600"))
}

///|
async test "get_locks 在没有锁时返回空数组" {
  let (client, _) = dav_client(
    dav_response(
      207,
      "application/xml",
      "<D:multistatus xmlns:D=\"DAV:\"><D:response>" +
      "<D:propstat><D:prop><D:lockdiscovery/></D:prop>" +
      "<D:status>HTTP/1.1 200 OK</D:status></D:propstat>" +
      "</D:response></D:multistatus>",
    ),
  )
  assert_eq(client.get_locks(path="/a.txt").length(), 0)
}

///|
async test "写操作带 lock_token 时自动补 If 头，可与 If-Match 共存" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(if_match="\"1\"", lock_token="tok-1"),
  )
  let request = mock.last_request().unwrap()
  assert_eq(request.headers.get("If-Match"), Some("\"1\""))
  assert_eq(request.headers.get("If"), Some("(<tok-1>)"))
  // 归一化后为空的令牌视为未设置
  let (blank, blank_mock) = dav_client(dav_response(201, "text/plain", ""))
  blank.mkdir(path="/dir2", conditions=@types.Conditions::new(lock_token=" "))
  assert_eq(blank_mock.last_request().unwrap().headers.get("If"), None)
}

///|
async test "带令牌的写请求遇到 423 抛 Api 且提示已锁定" {
  let (client, _) = dav_client(dav_response(423, "text/plain", ""))
  let error = capture_error(() => {
    client.delete(
      path="/a.txt",
      conditions=@types.Conditions::new(lock_token="tok-1"),
    )
  }).unwrap()
  guard! error.detail() is Api(status=423, operation="DELETE", message~)
  assert_true(message.contains("锁定"))
}
