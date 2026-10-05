## WebDAV 客户端项目申报书

### 基本信息

| 项目 | 内容 |
|------|------|
| 项目名称 | webdav |
| 参赛者 | q2316367743 |
| 联系方式 | 17762618644 |
| GitHub 仓库链接 | <https://github.com/q2316367743/webdav> |
| 项目方向 | MoonBit 网络协议基础库 / 文件同步基础设施 |


### 项目简介

`webdav` 将 WebDAV 协议（RFC 4918）的核心客户端能力带入 MoonBit 生态，为需要在 MoonBit 中接入云存储、实现文件同步、或构建网盘客户端工具的开发者提供类型安全、异步原生的 WebDAV 客户端库。库默认基于参赛者自研并发布于 mooncakes 的 moonhttp HTTP 客户端执行请求，执行层亦可通过 `Transport` 接口整体替换（moonhttp 依赖 moonbitlang/async 运行时，当前仅支持 native 后端，Wasm 支持随依赖生态演进列为后续方向）。项目面向三类使用者：**需要对接 Nextcloud/ownCloud 的 MoonBit 应用开发者**、**构建文件同步工具的 CLI 作者**、以及**在服务器端脚本与本地自动化任务中需要轻量级远程文件操作的场景**。

WebDAV 是文件同步和网盘接入领域的事实标准协议，Nextcloud、ownCloud、Apache mod_dav、SabreDAV 等主流服务端均以其为基础。当前 MoonBit 生态中没有任何 WebDAV 协议实现，开发者若想接入上述存储服务，只能从零手写 HTTP 请求和 XML 解析，且需要自行处理 207 Multi-Status 响应的复杂解析逻辑。`webdav` 的目标是填补这一空白，将协议细节封装为类型安全的 API，让下游开发者专注于业务逻辑而非协议实现。


### 核心功能范围

**本期交付范围（RFC 4918 核心）：**

- **HTTP 方法封装**：完整支持 PROPFIND（列目录 `list` / 单资源属性 `stat` / 按名取属性 `get_properties`）、PROPPATCH（`set_properties` 设置自定义属性）、MKCOL（`mkdir`）、GET（`get_file` 一次取全 / `download_file` 流式下载）、PUT（`put_file`）、DELETE、COPY/MOVE（`copy_path` / `move_path`，含 `overwrite` 开关与 `Destination` 头的 URL 编码）
- **Multi-Status 响应解析**：WebDAV 区别于普通 HTTP 的关键在于 `207 Multi-Status` 响应体。一个 PROPFIND 可能对部分资源部分成功、部分失败，需要解析 XML 响应体才能确定每个资源的具体状态。本库提供类型化的 Multi-Status 解析器，将 `response`、`href`、`propstat`、`status` 等 XML 元素解析为 `ParsedResource` 并映射为 `FileInfo` / 属性表，`href` 自动 percent 解码得到显示名
- **属性系统**：支持 PROPFIND 的 `allprop` 与指定属性（named prop）两种请求模式，解析标准 DAV 属性（`getcontentlength`、`getlastmodified`、`getetag`、`resourcetype`、`getcontenttype`、`creationdate` 等）；PROPPATCH 支持在自定义命名空间下设置属性
- **传输增强**：流式下载按块回调（`on_chunk` + 可调 `chunk_size`，内存占用与文件大小无关）、上传 / 下载进度回调（`Progress`，含 `percent()` 完成比例）、单请求超时（`timeout_ms`）、路径 percent 编解码（中文、空格等特殊文件名上传 / 下载往返一致）
- **认证支持**：Basic Auth（用户名 / 密码，均缺省时不携带认证头）
- **统一客户端入口**：提供 `create_webdav_client(WebdavConfig)` 构造客户端、`client.list(path)` 风格的 API，内部封装 HTTP 请求构造、XML 序列化/反序列化、错误映射；所有操作统一抛出 `WebdavError`，`detail()` 返回 `Http` / `Xml` / `Api` 分类，调用者以模式匹配分流处理

**明确不做的内容（后续扩展）：**

- CalDAV（RFC 4791）与 CardDAV（RFC 6352）
- RFC 3253 版本控制、RFC 3744 ACL、RFC 5323 搜索、RFC 6578 Sync Collection
- LOCK/UNLOCK 锁定与 Digest 认证
- 流式上传（当前 `put_file` 接收完整 `Bytes`，待 moonhttp 支持流式请求体后升级）
- Wasm 后端（moonhttp 依赖 moonbitlang/async 异步运行时，当前仅 native）


### 验收产物

- `q2316367743/webdav` 库（v0.1.0，Apache-2.0），可通过 `moon add q2316367743/webdav` 引入 MoonBit 项目
- **核心 API 可运行**：`create_webdav_client` → `list` / `stat` / `put_file` / `download_file` → Multi-Status 解析 → 统一错误分类的完整链路
- **测试覆盖**：基于 MockTransport 的单元测试（注入 200/201/204/207 及 404/405/409/412 等响应，不触网，断言请求方法 / 头 / URL 编码、207 解析与非期望状态码到错误的映射）；`src/main` 演示程序对真实 WebDAV 服务器（如本地部署的 hacdias/webdav）做端到端全流程校验，设置 `WEBDAV_TESTDATA` 时追加真实二进制文件与特殊文件名的往返一致性检查
- **端到端演示**：`src/main/main.mbt` 覆盖“建目录并上传文件（带进度）”“查属性 / 列目录”“流式下载”“移动 / 复制 / 删除并清理”完整场景
- **文档**：`README.mbt.md`（安装方式、快速上手、API 概览、已知限制）与 `docs/` 技术文档（01 架构与协议映射、02 API 参考）


### 移植或参考说明

| 项目 | 说明 |
|------|------|
| **参考项目 1** | `d-k-bo/webdav-rs`（Rust，Apache-2.0/MIT 双许可） |
| **参考项目 2** | `perry-mitchell/webdav-client`（TypeScript，MIT） |
| **参考项目 3** | `io-webdav` 的 RFC 模块化组织方式（按 RFC 拆分源代码树） |
| **本项目许可证** | Apache-2.0（与参考项目兼容） |

**参考范围说明：**

- **webdav-rs**：参考其“类型定义与 HTTP 执行层分离”的设计——协议层只生成请求对象、解析响应，不绑定特定 HTTP 客户端。本库落地为：WebDAV 协议逻辑（请求构造 / 响应解析）与执行层（`Transport` 接口）分离，默认执行层复用参赛者已有的 MoonBit HTTP 客户端 moonhttp，测试中以 MockTransport 注入
- **webdav-client**：参考其方法签名设计和配置选项组织方式（`createClient(url, options)` 风格对应本库的 `create_webdav_client(WebdavConfig)` 结构体配置 + 命名参数方法）
- **XML 解析依赖**：选用 mooncakes 上的 `Milky2018/xml`（命名空间感知的 Reader / Writer）。本库在其上构建 DAV 专属的 XML 序列化 / 反序列化层（`xmlutil` 包：PROPFIND / PROPPATCH 请求体生成、Multi-Status 解析）

**与原项目的差异：**

- 使用 MoonBit 原生类型系统表达 WebDAV 语义：Multi-Status 条目解析为 `FileInfo` / 属性表，而非动态语言的对象映射
- 错误以单构造器 `WebdavError` 包装分类枚举 `WebdavErrorDetail`（`Http` / `Xml` / `Api`），调用者模式匹配时必须显式处理每一类
- 执行层可插拔：默认 moonhttp，亦可通过 `create_webdav_client_with_transport` 注入任意 `Transport` 实现