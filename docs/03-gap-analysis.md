# 缺口分析与路线图

本文件列出「外部 WebDAV 客户端还缺什么接口」的结论：P0 是**现有 12 个接口的
协议正确性**问题（本轮已全部落地），P1 / P2 是能力扩展方向。

> 说明：本轮未能联网核实业界客户端（rclone / cadaver / davfs2 / Windows 映射盘 /
> Nextcloud 客户端）的接口清单——检索通道不可用，以下对标基于 RFC 4918（WebDAV）
> 与领域常识整理，**未经联网核实**，采用前建议逐条复核。

## P0：协议正确性（本轮已实现）

这些不是「缺新接口」，而是现有接口在真实服务器上会出错的地方。

| 缺口 | 现象 | 本轮做法 |
|------|------|---------|
| 207 的 propstat 状态被丢弃 | 属性不存在（404）与值为空无法区分，`get_properties` 把失败当空串 | `ParsedProp.status` + 逐段 propstat 状态归属；`find_prop` 只认 2xx（`src/xmlutil/multistatus.mbt`） |
| 部分失败不可见 | DELETE/MOVE/COPY 返回 207 且部分条目失败时，客户端当成功 | 允许 207 + `failures_from_multistatus` → `WebdavError::Partial(operation, failures)`（`src/client/status.mbt`） |
| href 不是路径 | 服务器回绝对 URL 或带 query 的 href，`list` 显示名错、自身排除失效 | `@types.href_to_path`：剥 scheme/authority、丢 query/fragment、percent 解码、去尾斜杠 |
| `exists` 依赖 HEAD | 服务器禁用 HEAD（405/501）时探测直接失败 | HEAD 405/501 → PROPFIND `Depth:0` 回退（`src/client/probe_ops.mbt`） |
| 无法探测服务器能力 | 不知道是否支持 LOCK、允许哪些方法 | 新增 `options(path?, signal?) -> ServerCapabilities`（`dav_class` / `allow` / `server`，含 `supports` / `has_lock`） |
| Depth 固定 | `list` 只能 Depth:1，无法整树列举 | `list(path~, depth?)` + `list_recursive`（Depth:infinity） |
| 无条件请求 | 不支持 If-Match / If-None-Match，无法安全覆盖 / 避免竞态 | 全部网络方法增 `conditions?`（`Conditions::new(if_match?, if_none_match?)`） |
| 无法取消 | 长传输无法中断 | 全部网络方法增 `signal? : AbortSignal`，取消映射为 `WebdavError::Cancelled(reason?)`（`@moonhttp` 的 `AbortController` 从门面再导出） |
| 错误面太窄 | 只有 Http / Xml / Api 三类，拿不到响应体与服务端解释 | `Api` 消息附响应体前 200 字符；新增 `Partial` / `Cancelled` 两个分支 |
| 成功响应信息丢失 | PUT/GET 只回 Unit / Bytes，ETag、Last-Modified、Location 拿不到 | `put_file -> PutResult`、`get_file -> GetResult`（**破坏性变更**，调用方加 `ignore` 或改用结果） |
| 属性读回丢失状态 | 只想看「哪些属性存在 / 失败原因」时无处可取 | `get_properties_with_status(...) -> Array[PropResult]` |

## P1：能力扩展（下一阶段候选）

按「使用频率 × 实现成本」粗排，尚未实现：

1. **LOCK / UNLOCK 与 `If:` 头**：`ServerCapabilities::has_lock()` 已能探测能力，
   但客户端还不能拿锁令牌做写操作（`If: (<opaquelocktoken:...>)`）。需要新增
   `lock(path~, owner?, timeout?) -> LockToken` / `unlock(path~, token~)`，
   并让 `send` 支持 `If` 头。
2. **从磁盘边读边发（`put_file_stream`）**：当前 `put_file` 的 `data` 契约是
   「完整内容已在内存」，大文件仍需先读进内存；moonhttp 0.5 的
   `with_data_from_stream(&@io.Reader)` 已就绪，接一个文件 Reader 即可。
3. **递归建目录（`mkdir(parents=true)`）**：现在 MKCOL 单级（父不存在得 409），
   补一个 `mkdir_all` 逐级 MKCOL、409/405 视为已存在。
4. **Range / 断点续传**：`download_file` 增 `range? : (Int, Int)`，
   `get_file` 同理；配套 `Accept-Ranges` / `Content-Range` 解析。
5. **认证面扩展**：moonhttp 只内置 Basic（`with_auth`）。Digest 需要自己拼
   `Authorization`（自定义头可绕过，moonhttp 的 `set_if_absent` 不覆盖用户头），
   Bearer / OAuth 同理；可选做 `AuthProvider` 抽象。
6. **重定向 / 代理 / 超时策略暴露**：moonhttp 的 `max_redirects`、
   `with_proxy`、按请求 timeout 目前被客户端默认配置挡住，可按需透传。
7. **属性删除与命名空间区分**：PROPPATCH 现在只 set；补 remove
   （`<D:remove>`），并让 `PropResult` 带上命名空间以免同名属性撞车。
8. **取消语义细化**：区分「用户取消」与「超时取消」（moonhttp 的
   `AbortSignal::reason()` 已能携带原因，`Cancelled(reason)` 已预留位置）。

## P2：更远的方向（按需）

- **REPORT / SEARCH / DeltaV（版本控制）**：moonhttp 的 `Method::Other` 可直接发
  任意扩展方法，XML 体可复用 xmlutil 的生成 / 解析框架，属于「加接口」而非「改架构」。
- **ACL 方法**（RFC 3744）：同上，`Other("ACL")` 可行。
- **深度 infinity 的流式解析**：现在 207 响应整体读进内存再解析，整树列举大目录时
  内存与响应体同阶；可改为 `Client::stream` + 增量 XML 解析。
- **并发与连接复用**：目前一次一个请求；批量操作（并行 `stat`、并发上传）需要
  连接池策略与限流。
- **重试与退避**：对 423（锁定）、5xx、连接重置的自动重试策略。
- **文件系统便捷层**：`download_file` 到本地路径、目录镜像 / 同步（更像 rclone 的
  `sync` 语义），属于上层工具而非客户端协议层。

## 与本次实现的对应关系

P0 的行已在代码中落地，逐项见 `docs/01-architecture.md` 的「协议映射」与
`docs/02-api.md` 的签名说明；P1 / P2 仅为本文件的路线图，**未实现**，
不构成当前 API 契约。
