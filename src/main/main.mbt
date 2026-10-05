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
    // 2. 上传（真实网络分块进度）
    let payload = @utf8.encode(
      "你好，WebDAV！这是 MoonBit 客户端上传的内容。\n",
    )
    client.put_file(
      path="/demo/hello.txt",
      data=payload,
      content_type="text/plain; charset=utf-8",
      on_progress=progress_printer("上传"),
    )
    println("✓ PUT /demo/hello.txt")
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
    // 6. 移动 / 复制
    client.move_path(src="/demo/hello.txt", dst="/demo/renamed.txt")
    println("✓ MOVE /demo/hello.txt → /demo/renamed.txt")
    client.copy_path(src="/demo/renamed.txt", dst="/demo/copy.txt")
    println("✓ COPY /demo/renamed.txt → /demo/copy.txt")
    // 7. 真实文件往返（binary.bin 走 64 KiB 分块进度；hello.txt 走特殊文件名编码）
    match @env.get_env_var("WEBDAV_TESTDATA") {
      Some(dir) => {
        let big : Bytes = @fs.read_file("\{dir}/binary.bin").binary()
        client.put_file(
          path="/demo/binary.bin",
          data=big,
          content_type="application/octet-stream",
          on_progress=progress_printer("上传 binary.bin"),
        )
        let big_sink = @buffer.Buffer::Buffer()
        client.download_file(
          path="/demo/binary.bin",
          on_chunk=fn(chunk) { big_sink.write_bytes(chunk) },
          on_progress=progress_printer("下载 binary.bin"),
        )
        check(
          big_sink.to_bytes() == big,
          "真实文件 binary.bin（\{big.length()} 字节）往返一致",
        )
        let text : Bytes = @fs.read_file("\{dir}/hello.txt").binary()
        client.put_file(
          path="/demo/中文 sample (v1).txt",
          data=text,
          content_type="text/plain; charset=utf-8",
        )
        let roundtrip = client.get_file(path="/demo/中文 sample (v1).txt")
        check(roundtrip == text, "特殊文件名上传下载往返一致")
        client.delete(path="/demo/中文 sample (v1).txt")
        client.delete(path="/demo/binary.bin")
      }
      None =>
        println("（未设置 WEBDAV_TESTDATA，跳过真实文件校验）")
    }
    // 8. 清理
    client.delete(path="/demo/copy.txt")
    client.delete(path="/demo/renamed.txt")
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
