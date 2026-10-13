// 锁注册表的白盒用例：路径归一化、祖先判定、记账去重与容量上限。
// 注册表本身不对外暴露，只能在本包里直接断言。

///|
/// 造一份空响应，只为拿到一个可构造客户端的传输层。
fn wb_raw_response() -> @transport.RawResponse {
  {
    status: 200,
    status_text: "",
    headers: @transport.Headers::new(),
    set_cookies: [],
    body: @transport.ResponseBody::from_bytes(b""),
  }
}

///|
/// 造一个开启重试的客户端（注册表用例只关心记账行为）。
fn wb_client(retry : Bool) -> WebdavClient {
  let mock = @transport.MockTransport::new(wb_raw_response())
  let transport : &@transport.Transport = mock
  create_webdav_client_with_transport(
    {
      base_url: "http://127.0.0.1:8080/dav/",
      username: None,
      password: None,
      timeout_ms: None,
      retry_on_423: Some(retry),
    },
    transport,
  )
}

///|
/// 造一条锁记录，令牌与深度可指定。
fn wb_lock(token : String, depth : String?) -> @types.ActiveLock {
  {
    token,
    scope: @types.LockScope::Exclusive,
    depth,
    owner: None,
    timeout: None,
    lockroot: None,
  }
}

///|
test "normalize_lock_path 压掉重复与结尾的斜杠，统一成单个前导斜杠" {
  assert_eq(normalize_lock_path("/a//b/"), "/a/b")
  assert_eq(normalize_lock_path("a/b"), "/a/b")
  assert_eq(normalize_lock_path("/"), "")
  assert_eq(normalize_lock_path(""), "")
}

///|
test "is_path_ancestor 只认同名或带斜杠的真前缀" {
  assert_true(is_path_ancestor("", "a/b"))
  assert_true(is_path_ancestor("a", "a/b"))
  assert_true(is_path_ancestor("a", "a"))
  assert_false(is_path_ancestor("a", "ab"))
  assert_false(is_path_ancestor("a/b", "a"))
}

///|
test "记账按 (令牌, 路径) 去重，深度用请求里声明的值兜底" {
  let client = wb_client(true)
  let lock = wb_lock("tok-1", None)
  client.remember_lock("/dir", lock, declared_depth="infinity")
  // 同一条锁（路径写法不同）不会记两遍
  client.remember_lock("/dir/", lock, declared_depth="infinity")
  assert_eq(client.known_locks.length(), 1)
  assert_eq(client.known_locks[0].depth, Some("infinity"))
  assert_eq(client.covering_lock_token("/dir/a.txt"), Some("tok-1"))
  assert_eq(client.covering_lock_token("/other"), None)
  client.forget_lock("/dir", "tok-1")
  assert_eq(client.known_locks.length(), 0)
}

///|
test "服务端回了 depth 时以响应为准，不覆盖成声明值" {
  let client = wb_client(true)
  client.remember_lock(
    "/dir",
    wb_lock("tok-2", Some("0")),
    declared_depth="infinity",
  )
  assert_eq(client.known_locks[0].depth, Some("0"))
  // depth 0 不覆盖后代，只覆盖自身
  assert_eq(client.covering_lock_token("/dir/a.txt"), None)
  assert_eq(client.covering_lock_token("/dir"), Some("tok-2"))
}

///|
test "注册表最多留 256 条，超出后淘汰最旧的一条" {
  let client = wb_client(true)
  for i = 0; i < 257; i = i + 1 {
    client.remember_lock(
      "/p" + i.to_string(),
      wb_lock("t" + i.to_string(), None),
    )
  }
  assert_eq(client.known_locks.length(), 256)
  assert_eq(client.covering_lock_token("/p0"), None)
  assert_eq(client.covering_lock_token("/p256"), Some("t256"))
}

///|
test "取最近记账的覆盖锁（后进先出）" {
  let client = wb_client(true)
  client.remember_lock(
    "/dir",
    wb_lock("outer", None),
    declared_depth="infinity",
  )
  client.remember_lock("/dir/a.txt", wb_lock("inner", None))
  assert_eq(client.covering_lock_token("/dir/a.txt"), Some("inner"))
  assert_eq(client.covering_lock_token("/dir/b.txt"), Some("outer"))
}
