///|
/// 演示 WebDAV 客户端全流程（跑法见 moon.pkg 头注释或 run_tests.sh）。
/// 设置 WEBDAV_TESTDATA 目录时，追加真实文件（binary.bin / hello.txt）
/// 的端到端往返校验；未设置时跳过，保持独立可跑。
async fn main {
  let base_url = @env.get_env_var("WEBDAV_URL").unwrap_or(
    "http://127.0.0.1:8080/",
  )
  let client = @webdav.create_webdav_client({
    base_url,
    username: @env.get_env_var("WEBDAV_USER"),
    password: @env.get_env_var("WEBDAV_PASS"),
    timeout_ms: Some(10_000),
    retry_on_423: None,
  })
  println("目标服务器: \{base_url}")
  // 进度打印节流：只在整数百分比变化时输出一行
  fn progress_printer(prefix : String) -> (@webdav.Progress) -> Unit {
    let mut last_percent = -1
    fn(progress : @webdav.Progress) {
      let percent = match progress.percent() {
        Some(ratio) => (ratio * 100.0).to_int()
        None => 50 // 长度未知：固定档位，仅在开始时打一次
      }
      if percent != last_percent {
        last_percent = percent
        let total_text = match progress.total {
          Some(total) => "\{progress.loaded}/\{total}"
          None => "\{progress.loaded}"
        }
        println("\{prefix}: \{percent}% (\{total_text})")
      }
    }
  }
  // 收集失败项：任何一步校验不过都打 ✗ 行（run_tests.sh 以此判定失败）
  let failures : Array[String] = []
  fn check(ok : Bool, step : String) -> Unit {
    if ok {
      println("✓ \{step}")
    } else {
      println("✗ \{step}")
      failures.push(step)
    }
  }
  try {
    // 1. 建目录
    client.mkdir(path="/demo")
    println("✓ MKCOL /demo")
    // 1b. 递归建目录（mkdir -p）：逐级 MKCOL，中间层不存在时也要建起来
    client.mkdir_all(path="/demo/相册/2024/深/层")
    let deep = client.stat(path="/demo/相册/2024/深/层")
    check(deep.is_dir, "MKCOL-ALL /demo/相册/2024/深/层")
    // 再调一次：所有层级已存在，服务端回 405 被跳过，且不抛错（幂等）
    client.mkdir_all(path="/demo/相册/2024/深/层")
    println("✓ MKCOL-ALL 幂等（已存在层级回 405 跳过）")
    // 2. 上传（真实网络分块进度）
    let payload = @utf8.encode(
      "你好，WebDAV！这是 MoonBit 客户端上传的内容。\n",
    )
    let put = client.put_file(
      path="/demo/hello.txt",
      data=payload,
      content_type="text/plain; charset=utf-8",
      on_progress=progress_printer("上传"),
    )
    let etag_text = match put.etag {
      Some(tag) => "，ETag \{tag}"
      None => ""
    }
    println("✓ PUT /demo/hello.txt（HTTP \{put.status}\{etag_text}）")
    // 3. 属性：stat 与自定义属性（部分服务端不持久化死属性，读回为空不算失败）
    let info = client.stat(path="/demo/hello.txt")
    let size = info.content_length.unwrap_or(-1)
    check(size == payload.length(), "STAT 大小一致（\{size} 字节）")
    client.set_properties(path="/demo/hello.txt", props=[("color", "red")])
    let props = client.get_properties(path="/demo/hello.txt", names=["color"])
    println(
      "✓ PROPPATCH color=\{props.get("color").unwrap_or("(服务端未存储)")}",
    )
    // 4. 列目录
    let items = client.list(path="/demo")
    println("✓ LIST /demo（\{items.length()} 项）")
    for item in items {
      let kind = if item.is_dir { "目录" } else { "文件" }
      println("  - [\{kind}] \{item.name}")
    }
    // 5. 流式下载（分块消费 + 进度）
    let sink = @buffer.Buffer::Buffer()
    client.download_file(
      path="/demo/hello.txt",
      on_chunk=fn(chunk) { sink.write_bytes(chunk) },
      chunk_size=16, // 演示用小分块，真实场景可用默认 64 KiB
      on_progress=progress_printer("下载"),
    )
    check(sink.to_bytes() == payload, "GET（流式）内容一致")
    // 5b. Range 区间下载：只取前 8 字节，服务端支持时回 206
    let head = @utf8.encode("你好，WebDAV！")
    let range_result = client.get_file(
      path="/demo/hello.txt",
      range=@webdav.ByteRange::from(end=head.length() - 1),
    )
    check(
      range_result.status == 206 && range_result.content == head,
      "GET（区间 206）内容一致",
    )
    // 5c. 断点续传：本地只有前半段（模拟上次中断的残留），
    //     resume 发 Range 从断点追加剩余字节；带 ETag 发 If-Range，
    //     服务端文件已变时自动回退 200 整体重写
    let local_target = @fs.tmpdir(prefix="webdav-resume-") + "/hello.txt"
    @fs.write_file(local_target, head)
    match put.etag {
      Some(tag) =>
        client.download_to_path_resume(
          path="/demo/hello.txt",
          local_path=local_target,
          etag=tag,
          chunk_size=4,
          on_progress=progress_printer("续传"),
        )
      None =>
        client.download_to_path_resume(
          path="/demo/hello.txt",
          local_path=local_target,
          chunk_size=4,
          on_progress=progress_printer("续传"),
        )
    }
    check(
      @fs.read_file(local_target).binary() == payload,
      "断点续传拼接后内容一致",
    )
    // 6. 移动 / 复制
    client.move_path(src="/demo/hello.txt", dst="/demo/renamed.txt")
    println("✓ MOVE /demo/hello.txt → /demo/renamed.txt")
    client.copy_path(src="/demo/renamed.txt", dst="/demo/copy.txt")
    println("✓ COPY /demo/renamed.txt → /demo/copy.txt")
    // 7. 真实文件往返
    //    binary.bin：本地路径流式上传（put_file_from_path，内容不整份读进
    //    内存）+ 流式下载写盘（download_to_path），逐字节比对；
    //    hello.txt：全量 Bytes 上传 + 全量下载，并覆盖特殊文件名编码。
    match @env.get_env_var("WEBDAV_TESTDATA") {
      Some(dir) => {
        let local_source = "\{dir}/binary.bin"
        let _ = client.put_file_from_path(
          path="/demo/binary.bin",
          local_path=local_source,
          content_type="application/octet-stream",
          on_progress=progress_printer("上传 binary.bin（本地路径）"),
        )
        let local_target = @fs.tmpdir(prefix="webdav-dl-") + "/binary.bin"
        client.download_to_path(
          path="/demo/binary.bin",
          local_path=local_target,
          on_progress=progress_printer("下载 binary.bin（写盘）"),
        )
        let expected : Bytes = @fs.read_file(local_source).binary()
        let actual : Bytes = @fs.read_file(local_target).binary()
        check(
          actual == expected,
          "本地路径流式往返 binary.bin（\{expected.length()} 字节）一致",
        )
        let text : Bytes = @fs.read_file("\{dir}/hello.txt").binary()
        let _ = client.put_file(
          path="/demo/中文 sample (v1).txt",
          data=text,
          content_type="text/plain; charset=utf-8",
        )
        let roundtrip = client.get_file(path="/demo/中文 sample (v1).txt")
        check(
          roundtrip.content == text,
          "特殊文件名上传下载往返一致",
        )
        client.delete(path="/demo/中文 sample (v1).txt")
        client.delete(path="/demo/binary.bin")
      }
      None =>
        println("（未设置 WEBDAV_TESTDATA，跳过真实文件校验）")
    }
    // 8. 能力探测与存在性判断
    // OPTIONS 拿服务端能力面，避免靠失败状态码猜支持面。
    let caps = client.options()
    println(
      "✓ OPTIONS：DAV 等级 \{caps.dav_class.length()} 个，允许方法 \{caps.allow.length()} 个，LOCK=\{caps.has_lock()}",
    )
    // exists 优先 HEAD；服务端不支持 HEAD（如 run_tests.sh 里 VERIFY_NO_HEAD_PREFIX
    // 命中的前缀）时回落到 PROPFIND Depth:0，结果不变。
    check(client.exists(path="/demo/renamed.txt"), "EXISTS /demo/renamed.txt")
    check(
      !client.exists(path="/demo/not-here.txt"),
      "EXISTS /demo/not-here.txt 为假",
    )
    // 9. 锁：LOCK / 无令牌写回 423 / 带令牌写 / 刷新 / 锁发现 / UNLOCK，
    //    以及共享锁、带标签 If、lock-null 清理与 423 自动重试（见 lock_demo.mbt）。
    //    服务端未声明 Class 2（DAV: 2）或 LOCK 时跳过，不计失败。
    if caps.has_lock() {
      for step in demo_lock(client, base_url) {
        failures.push(step)
      }
    } else {
      println("（服务端未声明 Class 2（DAV: 2），跳过锁校验）")
    }
    // 10. 清理
    client.delete(path="/demo/copy.txt")
    client.delete(path="/demo/renamed.txt")
    // mkdir_all 建的层级自底向上删（目录要先清空才能删）
    client.delete(path="/demo/相册/2024/深/层")
    client.delete(path="/demo/相册/2024/深")
    client.delete(path="/demo/相册/2024")
    client.delete(path="/demo/相册")
    client.delete(path="/demo")
    if failures.is_empty() {
      println("✓ 清理完成，演示全部通过")
    } else {
      println(
        "✗ 清理完成，但以下步骤校验未通过: \{failures.join("、")}",
      )
    }
  } catch {
    error => println("✗ 演示中断: \{error}")
  }
}
