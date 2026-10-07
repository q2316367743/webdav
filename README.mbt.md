# q2316367743/webdav

MoonBit WebDAV 客户端：文件上传 / 下载（全量字节、读取流、本地文件路径，流式 + 进度）、
目录、移动 / 复制、PROPFIND / PROPPATCH。基于
[moonhttp](https://mooncakes.io/docs/#/q2316367743/moonhttp/)
与 [Milky2018/xml](https://mooncakes.io/docs/#/Milky2018/xml/) 构建，仅 native 后端。

## 安装

```bash
moon add q2316367743/webdav
```

## 快速上手

```moonbit
async fn main {
  let client = @webdav.create_webdav_client({
    base_url: "http://127.0.0.1:8080/dav/",
    username: Some("user"),
    password: Some("pass"),
    timeout_ms: None,
  })
  // 上传 · 全量字节（进度按 64 KiB 分块节奏回调；返回值带 ETag 等元数据）
  let put = client.put_file(
    path="/demo/hello.txt",
    data=@utf8.encode("你好，WebDAV！"),
    content_type="text/plain; charset=utf-8",
    conditions=@webdav.Conditions::new(if_none_match="*"), // 仅当不存在时创建
    on_progress=fn(p) { println("上传 (\{p.loaded}/\{p.total})") },
  )
  println("已创建：\{put.created}，ETag：\{put.etag}")
  // 上传 · 本地文件（内部边读边发，内容不整份读进内存）
  ignore(
    client.put_file_from_path(
      path="/demo/big.bin",
      local_path="/Users/me/big.bin",
      content_type="application/octet-stream",
      on_progress=fn(p) { println("上传 big.bin \{p.loaded}/\{p.total}") },
    ),
  )
  // 上传 · 任意读取流（@fs.File / @io.pipe() 读端 / MemoryReader 都能接；
  // 传 content_length 走定长，不传走 chunked）
  // client.put_file_stream(path="/demo/stream.bin", reader=some_reader)
  // 列目录
  let items = client.list(path="/demo")
  for item in items {
    println("\{if item.is_dir { "[目录]" } else { "[文件]" }} \{item.name}")
  }
  // 流式下载 · 分块回调（内存消费）
  client.download_file(
    path="/demo/hello.txt",
    on_chunk=fn(chunk) { /* 逐块处理，如拼 Buffer / 算哈希 */ },
    on_progress=fn(p) { println("下载 \{p.loaded} 字节") },
  )
  // 流式下载 · 直接写本地文件（写盘是 async，客户端内部完成）
  client.download_to_path(path="/demo/big.bin", local_path="/Users/me/big.copy")
}
```

## 功能一览

| 类别 | 方法 |
|------|------|
| 上传 | `put_file`（全量 `Bytes`）、`put_file_stream`（`&@io.Reader`，可选长度）、`put_file_from_path`（本地文件路径）；三者都流式发送、都回 `PutResult` |
| 下载 | `get_file`（全量到内存，回 `GetResult`）、`download_file`（同步分块回调）、`download_to_path`（流式写本地文件） |
| 目录 | `mkdir`、`list`（可指定 `Depth`）、`list_recursive`（整树）、`stat`（属性）、`exists`（HEAD，不支持时自动回退 PROPFIND） |
| 移动 / 复制 | `move_path`、`copy_path`（覆盖语义 + `Depth`） |
| 自定义属性 | `set_properties` / `get_properties` / `get_properties_with_status`（PROPPATCH / 按名 PROPFIND，保留 404 状态） |
| 能力探测 | `options`（`DAV` / `Allow` / `Server` → `ServerCapabilities`） |
| 协议控制 | 所有方法的 `conditions?`（`If-Match` / `If-None-Match`）与 `signal?`（`AbortController` 取消） |

统一错误为 `WebdavError`（`detail()` 区分网络 / XML 解析 / 非期望状态码 /
207 部分失败 / 已取消 / 本地文件六类，`to_string()` 为中文人读描述）；
所有方法为 `async ... raise WebdavError`。

## 已知限制

- `mkdir` 单级创建（父目录不存在得 409）。
- 尚无 LOCK/UNLOCK 与 `If:` 锁令牌；`options().has_lock()` 只能探测服务端是否支持。
- 路径形态的传输只覆盖单文件；目录镜像 / 同步、Range 断点续传、
  push 型（Writer）上传仍是路线图。
- 更多缺口与 P1 / P2 路线图见 [docs/03-gap-analysis.md](docs/03-gap-analysis.md)。

## 文档

- [docs/01-architecture.md](docs/01-architecture.md) —— 架构与协议映射
- [docs/02-api.md](docs/02-api.md) —— API 参考
- [docs/03-gap-analysis.md](docs/03-gap-analysis.md) —— 缺口分析与路线图

## 开发

```bash
bash src/main/run_tests.sh  # 一键测试：起 WebDAV 服务端 → moon test → 真实全流程 → 关闭并汇总
moon test                   # 仅单元 / 黑盒测试（Mock 传输层，不触网）
moon run src/main           # 单独跑真实全流程演示（环境变量见 src/main/moon.pkg 头注释）
moon info && moon fmt
```
