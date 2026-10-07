// MOVE / COPY 的 207 部分失败、Depth 与 Overwrite 黑盒用例；
// helper 见 client_test.mbt。

///|
/// 只带 response 级 `<D:status>` 的 Multi-Status（MOVE / COPY / DELETE
/// 对单资源的逐条结果）。
fn status_only_multistatus(href : String, status_line : String) -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>" +
  href +
  "</D:href><D:status>" +
  status_line +
  "</D:status></D:response></D:multistatus>"
}

///|
async test "MOVE 207 有失败条目时抛 Partial" {
  let (client, _) = dav_client(
    multistatus_response(
      status_only_multistatus("/dav/b.txt", "HTTP/1.1 403 Forbidden"),
    ),
  )
  let error = capture_error(() => client.move_path(src="/a.txt", dst="/b.txt")).unwrap()
  match error.detail() {
    Partial(operation~, failures~) => {
      assert_eq(operation, "MOVE")
      assert_eq(failures.length(), 1)
      assert_eq(failures[0].href, "/dav/b.txt")
      assert_eq(failures[0].status, 403)
    }
    _ => assert_true(false, msg="应抛 Partial")
  }
}

///|
async test "COPY 207 全 2xx 视为成功" {
  let (client, _) = dav_client(
    multistatus_response(
      status_only_multistatus("/dav/copy.txt", "HTTP/1.1 201 Created"),
    ),
  )
  client.copy_path(src="/a.txt", dst="/copy.txt")
}

///|
async test "copy_path depth=Zero 发 Depth: 0，省略时不发 Depth" {
  let (client, mock) = dav_client(dav_response(201, "text/plain", ""))
  client.copy_path(src="/dir", dst="/dir2", depth=@types.Depth::Zero)
  let request = mock.last_request().unwrap()
  assert_eq(request.headers.get("Depth"), Some("0"))
  assert_eq(request.headers.get("Overwrite"), Some("T"))
  client.move_path(src="/a.txt", dst="/b.txt")
  assert_eq(mock.last_request().unwrap().headers.get("Depth"), None)
}
