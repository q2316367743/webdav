// lock-null 清理的黑盒用例（RFC 4918 §7.3）：只在能证明「仍是那个空资源」
// 时才删；锁已不在（404 / 409）继续收尾，其他错误照抛；
// 长度未知或非空一律不碰，删除时带 ETag 做条件请求。

///|
async test "空资源：释放锁后 HEAD 长度为 0，带 ETag 的条件 DELETE 删掉它" {
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response_with(200, "text/plain", "", [
      ("Content-Length", "0"),
      ("ETag", "\"e1\""),
    ]),
    dav_response(204, "text/plain", ""),
  ])
  assert_true(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 3)
  let request = mock.last_request().unwrap()
  assert_eq(request.http_method.to_string(), "DELETE")
  assert_eq(request.headers.get("If-Match"), Some("\"e1\""))
}

///|
async test "资源已经不在：HEAD 404 之后不去 DELETE" {
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response(404, "text/plain", ""),
  ])
  assert_false(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "资源非空：长度不为 0 就绝不删" {
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response_with(200, "text/plain", "hello", [("Content-Length", "5")]),
  ])
  assert_false(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "长度未知：服务端没给 Content-Length 时保守不删" {
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response(200, "text/plain", ""),
  ])
  assert_false(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "没有 ETag 时仍然删除，只是不带 If-Match" {
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response_with(200, "text/plain", "", [("Content-Length", "0")]),
    dav_response(204, "text/plain", ""),
  ])
  assert_true(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.last_request().unwrap().headers.get("If-Match"), None)
}

///|
async test "不支持 HEAD 的服务端：回到 PROPFIND 只判存在，长度未知不删" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/dav/new.txt</D:href>
    #|  <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let (client, mock) = dav_client_queue([
    dav_response(204, "text/plain", ""),
    dav_response(405, "text/plain", ""),
    multistatus_response(xml),
  ])
  assert_false(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 3)
}

///|
async test "释放锁返回 409（令牌对不上，锁已不在）时继续收尾" {
  let (client, mock) = dav_client_queue([
    dav_response(409, "text/plain", ""),
    dav_response(404, "text/plain", ""),
  ])
  assert_false(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  assert_eq(mock.request_count(), 2)
}

///|
async test "释放锁失败（500）直接上抛，连 HEAD 都不发" {
  let (client, mock) = dav_client_queue([dav_response(500, "text/plain", "")])
  let error = capture_error(() => {
    ignore(client.cleanup_lock_null(path="/new.txt", token="tok-1"))
  }).unwrap()
  guard! error.detail() is Api(status=500, operation="UNLOCK", message~)
  assert_true(message.contains("服务端"))
  assert_eq(mock.request_count(), 1)
}
