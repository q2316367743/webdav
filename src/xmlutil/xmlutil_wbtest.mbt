// xmlutil 的白盒用例：请求体生成的形状、207 解析对前缀差异 /
// 目录判定 / 中文 href / 自定义属性的宽容度。

///|
test "allprop 请求体是固定形状" {
  let body = propfind_allprop_body()
  assert_eq(
    body,
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>",
  )
}

///|
test "named PROPFIND 请求体按名展开" {
  let body = propfind_named_body(
    ["color", "priority"],
    ns_uri="urn:example:props",
  )
  assert_eq(
    body,
    "<D:propfind xmlns:D=\"DAV:\" xmlns:X=\"urn:example:props\">" +
    "<D:prop><X:color/><X:priority/></D:prop></D:propfind>",
  )
}

///|
test "PROPPATCH 请求体包含 set 与属性值" {
  let body = proppatch_set_body(
    [("color", "红&蓝"), ("note", "<重要>")],
    ns_uri="urn:example:props",
  )
  assert_eq(
    body,
    "<D:propertyupdate xmlns:D=\"DAV:\" xmlns:X=\"urn:example:props\">" +
    "<D:set><D:prop>" +
    "<X:color>红&amp;蓝</X:color>" +
    "<X:note>&lt;重要&gt;</X:note>" +
    "</D:prop></D:set></D:propertyupdate>",
  )
}

///|
test "解析 Apache 风格的 D: 前缀 207 响应" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:" xmlns:ns0="urn:example:props">
    #| <D:response>
    #|  <D:href>/dav/</D:href>
    #|  <D:propstat>
    #|   <D:prop>
    #|    <D:resourcetype><D:collection/></D:resourcetype>
    #|    <D:displayname>dav</D:displayname>
    #|    <D:getlastmodified>Tue, 15 Apr 2025 10:00:00 GMT</D:getlastmodified>
    #|   </D:prop>
    #|   <D:status>HTTP/1.1 200 OK</D:status>
    #|  </D:propstat>
    #| </D:response>
    #| <D:response>
    #|  <D:href>/dav/hello.txt</D:href>
    #|  <D:propstat>
    #|   <D:prop>
    #|    <D:displayname>hello.txt</D:displayname>
    #|    <D:getcontentlength>13</D:getcontentlength>
    #|    <D:getcontenttype>text/plain</D:getcontenttype>
    #|    <D:getetag>"abc123"</D:getetag>
    #|    <D:creationdate>2025-04-15T10:00:00Z</D:creationdate>
    #|    <D:resourcetype/>
    #|    <ns0:color>red</ns0:color>
    #|   </D:prop>
    #|   <D:status>HTTP/1.1 200 OK</D:status>
    #|  </D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let resources = parse_multistatus(xml)
  assert_eq(resources.length(), 2)
  let dir = resources[0].to_file_info()
  assert_true(dir.is_dir)
  assert_eq(dir.name, "dav")
  assert_eq(dir.href, "/dav/")
  assert_eq(dir.content_length, None)
  assert_eq(dir.last_modified, Some("Tue, 15 Apr 2025 10:00:00 GMT"))
  let file = resources[1].to_file_info()
  assert_false(file.is_dir)
  assert_eq(file.name, "hello.txt")
  assert_eq(file.content_length, Some(13))
  assert_eq(file.content_type, Some("text/plain"))
  assert_eq(file.etag, Some("\"abc123\""))
  assert_eq(file.created, Some("2025-04-15T10:00:00Z"))
  // 自定义死属性同时被收集
  assert_eq(
    resources[1].find_prop(local_name="color", ns_uri="urn:example:props"),
    Some("red"),
  )
}

///|
test "解析无前缀（默认命名空间）的 207 响应" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<multistatus xmlns="DAV:">
    #| <response>
    #|  <href>/dav/dir/</href>
    #|  <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat>
    #| </response>
    #|</multistatus>
  let resources = parse_multistatus(xml)
  assert_eq(resources.length(), 1)
  assert_true(resources[0].to_file_info().is_dir)
  assert_eq(resources[0].display_name(), "dir")
}

///|
test "中文与空格 href 的显示名被解码" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<d:multistatus xmlns:d="DAV:">
    #| <d:response>
    #|  <d:href>/dav/%E7%9B%B8%E5%86%8C/my%20file.txt</d:href>
    #|  <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
    #| </d:response>
    #|</d:multistatus>
  let resources = parse_multistatus(xml)
  let info = resources[0].to_file_info()
  assert_eq(info.name, "my file.txt")
  assert_eq(info.href, "/dav/%E7%9B%B8%E5%86%8C/my%20file.txt")
}

///|
test "非法 XML 抛出解析错误" {
  let error = try {
    ignore(parse_multistatus("<not-closed>"))
    None
  } catch {
    failure => Some(failure)
  }
  assert_true(error is Some(_))
}

///|
test "propname 请求体只要属性名" {
  assert_eq(
    propfind_propname_body(),
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
    "<D:propfind xmlns:D=\"DAV:\"><D:propname/></D:propfind>",
  )
}

///|
test "propstat 状态码逐段归属属性（200 / 404 / 403 混排）" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:" xmlns:X="urn:example:props">
    #| <D:response>
    #|  <D:href>/dav/a.txt</D:href>
    #|  <D:propstat>
    #|   <D:prop><X:color>red</X:color></D:prop>
    #|   <D:status>HTTP/1.1 200 OK</D:status>
    #|  </D:propstat>
    #|  <D:propstat>
    #|   <D:prop><X:absent/></D:prop>
    #|   <D:status>HTTP/1.1 404 Not Found</D:status>
    #|  </D:propstat>
    #|  <D:propstat>
    #|   <D:prop><X:secret>hidden</X:secret></D:prop>
    #|   <D:status>HTTP/1.1 403 Forbidden</D:status>
    #|  </D:propstat>
    #| </D:response>
    #|</D:multistatus>
  let resources = parse_multistatus(xml)
  let props = resources[0].props
  assert_eq(props.length(), 3)
  assert_eq(props[0].name, "color")
  assert_eq(props[0].value, "red")
  assert_eq(props[0].status, 200)
  assert_eq(props[1].name, "absent")
  assert_eq(props[1].status, 404)
  assert_eq(props[2].name, "secret")
  assert_eq(props[2].status, 403)
  // find_prop 只认 2xx：404 / 403 的属性视为「没有这个属性」
  let ns = "urn:example:props"
  assert_eq(resources[0].find_prop(local_name="color", ns_uri=ns), Some("red"))
  assert_eq(resources[0].find_prop(local_name="absent", ns_uri=ns), None)
  assert_eq(resources[0].find_prop(local_name="secret", ns_uri=ns), None)
}

///|
test "status 排在 prop 之前也能归属，response 级 status 单独解析" {
  let xml =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<D:multistatus xmlns:D="DAV:" xmlns:X="urn:example:props">
    #| <D:response>
    #|  <D:href>/dav/ok.txt</D:href>
    #|  <D:propstat>
    #|   <D:status>HTTP/1.1 200 OK</D:status>
    #|   <D:prop><X:color>blue</X:color></D:prop>
    #|  </D:propstat>
    #| </D:response>
    #| <D:response>
    #|  <D:href>/dav/b.txt</D:href>
    #|  <D:status>HTTP/1.1 403 Forbidden</D:status>
    #|  <D:responsedescription>无权限</D:responsedescription>
    #| </D:response>
    #|</D:multistatus>
  let resources = parse_multistatus(xml)
  assert_eq(resources[0].status, None)
  assert_eq(resources[0].props[0].status, 200)
  // response 级 status 不是 propstat 状态
  assert_eq(resources[1].status, Some(403))
  assert_eq(resources[1].responsedescription, Some("无权限"))
}
