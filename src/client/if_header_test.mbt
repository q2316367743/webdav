// `If` 头的黑盒用例：多列表析取 / 列表内合取、`Not`、ETag、带标签列表、
// 与 `lock_token` 的组合顺序，以及本地就能拦下的非法组合（不发请求）。
// 断言全部打在 MockTransport 抓到的请求头上，不触网。

///|
async test "If 头支持多列表析取与列表内合取" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(if_lists=[
      @types.IfList::new([
        @types.IfCondition::token("tok-1"),
        @types.IfCondition::etag("\"v1\""),
      ]),
      @types.IfList::new([@types.IfCondition::token("tok-2")]),
    ]),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If"),
    Some("(<tok-1> [\"v1\"]) (<tok-2>)"),
  )
}

///|
async test "Not 前缀只作用于紧随其后的那一条条件" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(if_lists=[
      @types.IfList::new([
        @types.IfCondition::token("tok-1", negated=true),
        @types.IfCondition::etag("\"v1\""),
        @types.IfCondition::etag("\"v2\"", negated=true),
      ]),
    ]),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If"),
    Some("(Not <tok-1> [\"v1\"] Not [\"v2\"])"),
  )
}

///|
async test "带标签的 If 列表渲染出资源标签" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(if_lists=[
      @types.IfList::new(
        [@types.IfCondition::token("tok-1")],
        resource_tag="/dir",
      ),
    ]),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If"),
    Some("</dir> (<tok-1>)"),
  )
}

///|
async test "带标签模式下的锁令牌渲染成独立的带标签列表" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(lock_token="tok-2", if_lists=[
      @types.IfList::new(
        [@types.IfCondition::token("tok-1")],
        resource_tag="/dir",
      ),
    ]),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If"),
    Some("</dir> (<tok-1>) <http://127.0.0.1:8080/dav/dir> (<tok-2>)"),
  )
}

///|
async test "无标签列表与锁令牌同在一个 If 头里，列表在前令牌在后" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.mkdir(
    path="/dir",
    conditions=@types.Conditions::new(lock_token="tok-2", if_lists=[
      @types.IfList::new([@types.IfCondition::token("tok-1")]),
    ]),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("If"),
    Some("(<tok-1>) (<tok-2>)"),
  )
}

///|
async test "无标签与带标签列表混用时本地拦下，不发请求" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    client.mkdir(
      path="/dir",
      conditions=@types.Conditions::new(if_lists=[
        @types.IfList::new([@types.IfCondition::token("tok-1")]),
        @types.IfList::new(
          [@types.IfCondition::token("tok-2")],
          resource_tag="/dir",
        ),
      ]),
    )
  }).unwrap()
  guard! error.detail() is Api(status=400, operation="MKCOL", message~)
  assert_true(message.contains("不能混用"))
  assert_eq(mock.request_count(), 0)
}

///|
async test "空的 If 列表本地拦下，不发请求" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    client.mkdir(
      path="/dir",
      conditions=@types.Conditions::new(if_lists=[@types.IfList::new([])]),
    )
  }).unwrap()
  guard! error.detail() is Api(status=400, operation="MKCOL", message~)
  assert_true(message.contains("至少要有一个条件"))
  assert_eq(mock.request_count(), 0)
}

///|
async test "带标签列表的资源标签为空时本地拦下" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    client.mkdir(
      path="/dir",
      conditions=@types.Conditions::new(if_lists=[
        @types.IfList::new(
          [@types.IfCondition::token("tok-1")],
          resource_tag="",
        ),
      ]),
    )
  }).unwrap()
  guard! error.detail() is Api(status=400, operation="MKCOL", message~)
  assert_true(message.contains("资源标签"))
  assert_eq(mock.request_count(), 0)
}

///|
async test "If 条件里的状态令牌归一化后为空时本地拦下" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  let error = capture_error(() => {
    client.mkdir(
      path="/dir",
      conditions=@types.Conditions::new(if_lists=[
        @types.IfList::new([@types.IfCondition::token(" ")]),
      ]),
    )
  }).unwrap()
  guard! error.detail() is Api(status=400, operation="MKCOL", message~)
  assert_true(message.contains("锁令牌不能为空"))
  assert_eq(mock.request_count(), 0)
}
