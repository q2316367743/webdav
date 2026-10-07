// percent 编解码的白盒用例：unreserved 保留、空格/中文/保留字符编码、
// 非法转义与往返一致性。

///|
test "unreserved 与斜杠原样保留" {
  assert_eq(percent_encode_path("/a/b-c_d.e~f/0123"), "/a/b-c_d.e~f/0123")
}

///|
test "空格编码为 %20 而非加号" {
  assert_eq(percent_encode_path("/my file.txt"), "/my%20file.txt")
}

///|
test "中文字符按 UTF-8 逐字节编码" {
  assert_eq(percent_encode_path("/中.md"), "/%E4%B8%AD.md")
}

///|
test "URL 保留字符被编码，避免破坏路径语义" {
  assert_eq(percent_encode_path("/a?b#c&d"), "/a%3Fb%23c%26d")
}

///|
test "percent_decode 还原常见编码" {
  assert_eq(percent_decode("/dav/%E4%B8%AD.md"), "/dav/中.md")
  assert_eq(percent_decode("/my%20file.txt"), "/my file.txt")
}

///|
test "非法转义序列原样保留" {
  assert_eq(percent_decode("/a%2"), "/a%2")
  assert_eq(percent_decode("/a%zz"), "/a%zz")
}

///|
test "编码解码往返一致" {
  let path = "/相册/2025 花开/IMG_0001 (1).jpg"
  assert_eq(percent_decode(percent_encode_path(path)), path)
}

///|
test "href_to_path 剥掉 scheme 与 authority" {
  assert_eq(href_to_path("http://127.0.0.1:8080/dav/a.txt"), "/dav/a.txt")
  assert_eq(href_to_path("https://example.com/dav/dir/"), "/dav/dir")
}

///|
test "href_to_path 丢弃 query / fragment 并 percent 解码" {
  assert_eq(href_to_path("/dav/my%20file.txt?rev=2"), "/dav/my file.txt")
  assert_eq(href_to_path("/dav/a.txt#frag"), "/dav/a.txt")
}

///|
test "href_to_path 保留根路径并归一化相对 href" {
  assert_eq(href_to_path("/"), "/")
  assert_eq(href_to_path("/dav/"), "/dav")
  assert_eq(href_to_path("http://127.0.0.1:8080/dav/"), "/dav")
}
