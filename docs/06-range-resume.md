# 06 Range 区间下载与断点续传

对应 `docs/03-gap-analysis.md` 原 P1 候选第 1 条（已落地，见其「Range / 断点续传」章节）。本轮交付两层能力：

| 能力 | 结论 |
|------|------|
| 三个下载方法的 `range?`（RFC 7233） | 已实现：`get_file` / `download_file` / `download_to_path`，206 / 200 双状态放行 |
| `ByteRange` 区间构造（闭区间 / 开放端 / 后缀） | 已实现：`from(start?, end?)` / `suffix(length)` |
| `Content-Range` 解析 | 已实现：`GetResult.content_range`（206）、`parse_unsatisfied_range_total`（416 的 `bytes */total`） |
| 断点续传 | 已实现：`download_to_path_resume`，以本地残留为起点追加，`If-Range` 防服务端文件已变 |
| 多区间（`bytes=0-1,5-9`）与 multipart/byteranges 响应 | **不做**：单区间覆盖断点续传与分块取回；multipart 解析成本高、无调用方诉求 |
| `Accept-Ranges` 显式暴露 | **不做**：探测「服务端是否支持 Range」直接发一次小区间请求看是否 206，比读响应头更可靠；`resume` 本身已自动回退 |
| 下载位置的 push 形态（Writer / 回调里 await 写盘） | 仍不做（P2） |

`GetResult` 新增字段属于**破坏性变更**（文中 0.3.0 为发布计划编号，
实际版本号一律以 `moon.mod` 的 `version` 为准）。
所有 `Int32` 均指源码中的 `Int32`（生成的 `.mbti` 里规范化显示为 `Int`）。

---

## 1. 类型契约

`src/types/range.mbt`：

```moonbit
// 请求侧：字节区间（只能经工厂构造，保证取值合法）
pub struct ByteRange { start : Int32; end : Int32? }   // 字段只读
pub fn ByteRange::from(start? : Int32, end? : Int32) -> ByteRange
pub fn ByteRange::suffix(length : Int32) -> ByteRange
pub fn ByteRange::header_value(self) -> String          // 渲染 Range 头的值

// 响应侧：206 的 Content-Range（bytes first-last/total）
pub(all) struct ContentRange { first : Int32; last : Int32; total : Int32? }
pub fn parse_content_range(String) -> ContentRange?          // 形态不符 → None
pub fn parse_unsatisfied_range_total(String) -> Int32?       // 416 的 bytes */total
```

- 字节从 0 计，`end` 为**含端**（`from(start=0, end=7)` 取前 8 字节）；
- `from(start=5)` → `bytes=5-`（到末尾），`from(start=5, end=8)` → `bytes=5-8`；
- 后缀形式（取末尾 N 字节）以负数 `start = -N` 存储，`suffix(100)` → `bytes=-100`；
- 解析兼容 `bytes 500-999/3000`（RFC，空格）与 `bytes=500-999/3000`（等号）两种前缀，
  总长 `*` 时 `total` 为 `None`；`bytes */total` 形态属于 416，由
  `parse_unsatisfied_range_total` 解析。

`GetResult`（`src/types/result.mbt`）新增末位字段：

```moonbit
content_range : ContentRange?   // 206 且头可解析时有值；200 回退为 None
```

注意 206 的 `Content-Length` 是**区间**长度而非资源总长，`GetResult.content_length`
保持「响应头原样」的语义，资源总长从 `content_range.total` 取。

## 2. 三个下载方法的 `range?` 语义

`src/client/download_ops.mbt`，参数顺序统一为 `path~ → (on_chunk~) → chunk_size? →
range? → conditions? → on_progress? → signal?`：

- 带 `range?` 时请求附 `Range` 头，期望状态码集合从 `[200]` 变为 `[200, 206]`
  （`open_get_stream` / `get_file` 的 `check_status`）；
- **200 回退**：服务端忽略 Range（不支持）时返回全量，方法正常成功，调用方以
  `status` / `content_range` 区分拿到的是区间还是全量；
- `download_file` / `download_to_path` 的进度按**本次响应**计：`loaded` 从 0 起累计，
  `total` 取响应 `Content-Length`（206 时即区间长度）；
- `download_to_path` 的写盘循环抽成 `write_stream_to_file(stream, local_path~,
  append~, offset~, total~, …)`，与 0.2.0 行为一致（先请求后建文件、失败残留不删除、
  `Io` 错误文案不变），`append=false, offset=0` 即原路径。

## 3. 断点续传：`download_to_path_resume`

`src/client/download_resume.mbt`。签名：

```moonbit
pub async fn WebdavClient::download_to_path_resume(
  self, path~ : String, local_path~ : String,
  etag? : String, chunk_size? : Int32,
  on_progress? : (Progress) -> Unit, signal? : AbortSignal,
) -> Unit raise WebdavError
```

状态机（起点 `offset` = 本地已有字节数，不存在按 0）：

| 前置 / 响应 | 行为 |
|------|------|
| `offset == 0` | 直接委托 `download_to_path` 全量下载（不发 Range） |
| 请求 | `Range: bytes=offset-`；`etag?` 提供时附 `If-Range` |
| **206** | 解析 `Content-Range`：`first != offset` → `Api`（续传不安全）；缺失 / 不可解析 → `Api`；否则 `@fs.open(append=true, create_mode=OpenOrCreate)` 追加写 |
| **200** | 服务端忽略 Range，或 `If-Range` 判定资源已变 → 截断重写（等价全量下载） |
| **416** | `bytes */total` 且 `total == offset` → 本地已完整，**成功返回**；否则 `Api(416)` |
| 其他 | 照常 `Api`（404 等），本地残留不动 |

保证：

- **进度是绝对值**：`loaded` 从 `offset` 起累计，`total` 取 `Content-Range.total`
  （200 回退时取 `Content-Length`）——调用方直接展示「整个文件」的进度；
- **成功返回 = 文件完整**：206 / 200 写完后校验本地大小与总长一致（总长已知时），
  不一致抛 `Api`；416-已完成分支天然满足；
- **`etag?` 是防损坏的关键**：`If-Range` 只认强校验器 ETag（含引号原样，来自上次
  `get_file` / `put_file` 的结果）。省略则裸续传——服务端文件在两次下载之间被整体
  替换时可能拼出损坏文件，调用方自行权衡。

`offset` / 完成校验读本地大小用 `@fs.file_size`（`Int64`），超过 `Int32` 表示范围
（>2GB）抛 `Io`（与全库 `Int32` 口径一致，见 §6）。

## 4. 关键文件

| 文件 | 职责 |
|------|------|
| `src/types/range.mbt` | `ByteRange` / `ContentRange`、`Range` 头渲染、两种 `Content-Range` 解析 |
| `src/types/result.mbt` | `GetResult.content_range` 字段 |
| `src/client/download_ops.mbt` | 三方法的 `range?`、`open_get_stream` 206 放行、`write_stream_to_file` 公共写盘循环 |
| `src/client/download_resume.mbt` | `download_to_path_resume` 状态机、`resume_offset`、`verify_resumed_size` |
| `src/client/status.mbt` | `status_message` 补 206 / 416 中文注解 |
| `src/webdav.mbt` | 门面重导出 `ByteRange` / `ContentRange` |
| `src/main/main.mbt` | e2e 演示第 5b / 5c 步：区间 206 校验 + 残留文件续传拼接比对 |
| `src/main/testdata/verify_server.py` | e2e 兜底服务端：`do_GET` 经 `parse_bytes_range` 按 RFC 7233 回 206 / 416 |

## 5. 测试矩阵

黑盒（`src/client/download_range_test.mbt`，16 例，Mock 传输层不触网）：

- Range 头形状：闭区间 `bytes=5-8`、开放端 `bytes=5-`、后缀 `bytes=-4`、缺省起点 `bytes=0-`；
- `get_file`：206 的 `content_range` 解析、200 回退返回全量、416 → `Api`（消息含
  「区间不满足」）；
- `download_file` / `download_to_path`：区间内容分块回调 / 落盘、进度按区间计；
- `download_to_path_resume`：本地无文件（不发 Range）、206 追加（Range / If-Range 头、
  绝对进度 `[7,9,10]`）、200 回退截断重写、416 且已下完视为成功、416 未下完抛
  `Api(416)`、206 起点不符抛 `Api`、206 缺 `Content-Range` 抛 `Api`、远端 404 不动本地文件；
- 解析单元：标准 / 等号前缀 / 未知总长 `*` / 非法形态 / `bytes */total`。

e2e（`bash src/main/run_tests.sh`，两阶段全绿）：brew webdav（hacdias 5.x，Go
`http.ServeContent`）与 python 兜底 `verify_server.py`（`parse_bytes_range`）
都真实返回 206，区间内容与续传拼接逐字节比对通过，续传进度按绝对值输出
（`22/61 → 61/61`）。

## 6. 已知限制

- **单区间**：不发多区间 `Range`，不解析 `multipart/byteranges`（服务端把多区间
  合并成 multipart 时，本层不会遇到——因为从不发多区间请求）；
- **`Int32` 口径**：区间端点、进度、`Content-Range` 数值均受 `Int32` 上限约束，
  >2GB 资源不支持区间下载与续传（`resume` 对超限本地文件抛 `Io`）；这是全库
  既有口径（`Content-Length` 解析同限），不是本次引入；
- **`If-Range` 仅支持 ETag**：HTTP-date 形态不造（秒级精度弱保证，容易误判）；
- **裸续传的风险自担**：不带 `etag` 时 206 只证明「区间存在」，不证明「资源未变」；
- 续传不接 `conditions?`：`If-Range` 本身就是本请求的条件，且 GET 上 `If-Match`
  与续传语义不搭；需要锁令牌的场景先用 `get_locks` 自查；
- `download_to_path` / `resume` 中途失败仍会留下部分文件（现状语义，正是续传的
  输入），需要原子性时写到临时路径再 rename。
