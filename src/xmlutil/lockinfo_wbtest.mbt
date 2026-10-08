// lockinfo / lockdiscovery 的白盒用例：请求体形状、
// 对 hacdias 与 mod_dav 两种真实响应体的解析、前缀无关与容错边界。

///|
test "lockinfo 请求体是独占写锁形状" {
  let body = lockinfo_body(owner="demo@example.com")
  assert_eq(
    body,
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:lockinfo xmlns:D=\"DAV:\">" +
    "<D:lockscope><D:exclusive/></D:lockscope>" +
    "<D:locktype><D:write/></D:locktype>" +
    "<D:owner>demo@example.com</D:owner>" +
    "</D:lockinfo>",
  )
}

///|
test "lockinfo 省略 owner 时不发 owner 元素" {
  let body = lockinfo_body()
  assert_true(!body.contains("owner"))
}

///|
test "lockinfo 转义 owner 里的 XML 特殊字符" {
  let body = lockinfo_body(owner="a&b<c>")
  assert_true(body.contains("<D:owner>a&amp;b&lt;c&gt;</D:owner>"))
}

///|
test "解析 hacdias 风格的 lockdiscovery（裸数字令牌）" {
  let xml =
    #|<?xml version="1.0" encoding="UTF-8"?>
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:response>
    #|  <D:href>/a.txt</D:href>
    #|  <D:propstat>
    #|   <D:prop>
    #|    <D:lockdiscovery>
    #|     <D:activelock>
    #|      <D:locktype><D:write/></D:locktype>
    #|      <D:lockscope><D:exclusive/></D:lockscope>
    #|      <D:depth>infinity</D:depth>
    #|      <D:owner></D:owner>
    #|      <D:timeout>Second-3600</D:timeout>
    #|      <D:locktoken><D:href>1791426373</D:href></D:locktoken>
    #|      <D:lockroot><D:href>/a.txt</D:href></D:lockroot>
    #|     </D:activelock>
    #|    </D:lockdiscovery>
    #|   </D:prop>
    #|   <D:status>HTTP/1.1 200 OK</D:status>
    #|  </D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let locks = parse_lockdiscovery(xml)
  assert_eq(locks.length(), 1)
  let lock = locks[0]
  assert_eq(lock.token, "1791426373")
  assert_eq(lock.scope, "exclusive")
  assert_eq(lock.depth, Some("infinity"))
  assert_eq(lock.timeout, Some("Second-3600"))
  assert_eq(lock.lockroot, Some("/a.txt"))
  // 空的 <D:owner></D:owner> 归成 None
  assert_eq(lock.owner, None)
}

///|
test "解析 mod_dav 风格：小写前缀 + owner 内嵌 href" {
  let xml =
    #|<d:lockdiscovery xmlns:d="DAV:">
    #| <d:activelock>
    #|  <d:lockscope><d:exclusive/></d:lockscope>
    #|  <d:locktype><d:write/></d:locktype>
    #|  <d:owner>张三 <d:href>mailto:zhangsan@example.com</d:href></d:owner>
    #|  <d:timeout>Infinite</d:timeout>
    #|  <d:locktoken><d:href>opaquelocktoken:abc-123</d:href></d:locktoken>
    #|  <d:lockroot><d:href>http://h/dav/a.txt</d:href></d:lockroot>
    #| </d:activelock>
    #|</d:lockdiscovery>
  let locks = parse_lockdiscovery(xml)
  assert_eq(locks.length(), 1)
  let lock = locks[0]
  assert_eq(lock.token, "opaquelocktoken:abc-123")
  assert_eq(lock.timeout, Some("Infinite"))
  assert_eq(lock.lockroot, Some("http://h/dav/a.txt"))
  // owner 的直接文本与嵌套 href 文本都算进 owner
  assert_true(lock.owner is Some(text) && text.contains("张三"))
  assert_true(
    lock.owner is Some(text) && text.contains("mailto:zhangsan@example.com"),
  )
}

///|
test "空 lockdiscovery 与自闭合元素都不产出锁" {
  let empty = parse_lockdiscovery(
    "<D:lockdiscovery xmlns:D=\"DAV:\"></D:lockdiscovery>",
  )
  assert_eq(empty.length(), 0)
  let self_closing = parse_lockdiscovery("<D:lockdiscovery xmlns:D=\"DAV:\"/>")
  assert_eq(self_closing.length(), 0)
}

///|
test "自闭合的 lockscope 也能定出作用域" {
  let xml =
    #|<D:activelock xmlns:D="DAV:">
    #| <D:lockscope><D:shared/></D:lockscope>
    #| <D:locktoken><D:href>tok-shared</D:href></D:locktoken>
    #|</D:activelock>
  let locks = parse_lockdiscovery(xml)
  assert_eq(locks.length(), 1)
  assert_eq(locks[0].scope, "shared")
  assert_eq(locks[0].timeout, None)
}

///|
test "非 DAV 命名空间的同名元素不参与解析" {
  let xml =
    #|<x:activelock xmlns:x="urn:example:other">
    #| <x:locktoken><x:href>不是锁令牌</x:href></x:locktoken>
    #|</x:activelock>
  assert_eq(parse_lockdiscovery(xml).length(), 0)
}

///|
test "没有 locktoken 的 activelock 被丢弃" {
  let xml =
    #|<D:multistatus xmlns:D="DAV:">
    #| <D:activelock>
    #|  <D:lockscope><D:exclusive/></D:lockscope>
    #|  <D:timeout>Second-60</D:timeout>
    #| </D:activelock>
    #| <D:activelock>
    #|  <D:lockscope><D:exclusive/></D:lockscope>
    #|  <D:locktoken><D:href>tok-2</D:href></D:locktoken>
    #| </D:activelock>
    #|</D:multistatus>
  let locks = parse_lockdiscovery(xml)
  assert_eq(locks.length(), 1)
  assert_eq(locks[0].token, "tok-2")
}

///|
test "非法 XML 抛 XmlError" {
  let error = try {
    ignore(parse_lockdiscovery("<D:lockdiscovery"))
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}
