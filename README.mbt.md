# q2316367743/webdav

MoonBit WebDAV 客户端：文件上传 / 下载（流式 + 进度）、目录、移动 / 复制、
PROPFIND / PROPPATCH。基于 [moonhttp](https://mooncakes.io/docs/#/q2316367743/moonhttp/)
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
  // 上传（进度按 64 KiB 分块节奏回调）
  client.put_file(
    path="/demo/hello.txt",
    data=@utf8.encode("你好，WebDAV！"),
    content_type="text/plain; charset=utf-8",
    on_progress=fn(p) { println("上传 (\{p.loaded}/\{p.total})") },
  )
  // 列目录
  let items = client.list(path="/demo")
  for item in items {
    println("\{if item.is_dir { "[目录]" } else { "[文件]" }} \{item.name}")
  }
  // 流式下载（分块消费，内存占用与文件大小无关）
  client.download_file(
    path="/demo/hello.txt",
    on_chunk=fn(chunk) { /* 逐块写文件 */ },
    on_progress=fn(p) { println("下载 \{p.loaded} 字节") },
  )
}
```

## 功能一览

| 类别 | 方法 |
|------|------|
| 上传 / 下载 | `put_file`（全量 + 进度）、`get_file`（全量）、`download_file`（流式 + 进度） |
| 目录 | `mkdir`、`list`（列目录）、`stat`（属性）、`exists` |
| 移动 / 复制 | `move_path`、`copy_path`（可控制覆盖语义） |
| 自定义属性 | `set_properties` / `get_properties`（PROPPATCH / 按名 PROPFIND） |

统一错误为 `WebdavError`（`detail()` 区分网络 / XML 解析 / 非期望状态码三类，
`to_string()` 为中文人读描述）；所有方法为 `async ... raise WebdavError`。

## 已知限制

- 上传是全量传输：moonhttp 0.4 请求体为一次性字节，`put_file` 接受完整 `Bytes`；
  moonhttp 支持流式请求体后将同步升级（接口形态已预留）。
- `mkdir` 单级创建（父目录不存在得 409）；递归创建与 LOCK/UNLOCK 留待后续。

## 文档

- [docs/01-architecture.md](docs/01-architecture.md) —— 架构与协议映射
- [docs/02-api.md](docs/02-api.md) —— API 参考

## 开发

```bash
bash src/main/run_tests.sh  # 一键测试：起 WebDAV 服务端 → moon test → 真实全流程 → 关闭并汇总
moon test                   # 仅单元 / 黑盒测试（Mock 传输层，不触网）
moon run src/main           # 单独跑真实全流程演示（环境变量见 src/main/moon.pkg 头注释）
moon info && moon fmt
```
