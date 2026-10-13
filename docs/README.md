# WebDAV 客户端技术文档索引

供后续开发 / AI 参考的文档目录，新增 / 更新 / 删除文档后必须同步本索引。

| 文档 | 标题 | 描述 |
|------|------|------|
| [01-architecture.md](01-architecture.md) | 架构与协议映射 | 包结构与依赖方向、每个 WebDAV 操作 ↔ HTTP 方法 / 头 / 请求体 / 期望状态码的映射表、关键实现决策（状态接管与 207 部分失败、上传三形态 send_put / BytesReader、下载三形态与 open_get_stream、本地文件句柄的打开与关闭、href 归一、propstat 状态归属、能力探测与 HEAD 回退、条件请求与取消、锁与 `If: (<令牌>)`） |
| [02-api.md](02-api.md) | API 参考 | 公开类型与全部方法的契约：WebdavConfig（含 `retry_on_423`）、条件请求（锁令牌 `lock_token` 与 `If` 列表 `if_lists`）与取消、进度回调节奏、锁（`lock`（独占 / 共享）/ `refresh_lock` / `unlock` / `get_locks` / `cleanup_lock_null`）与 `ActiveLock` / `LockScope` / `LockResult`、错误分类（含 423/409/412、207 部分失败与本地 `Io`）、三种上传形态、本地文件形态（先请求后建文件 / 失败残留 / 长度快照 / 超时口径） |
| [03-gap-analysis.md](03-gap-analysis.md) | 缺口分析与路线图 | 外部 WebDAV 客户端还缺什么：传输形态补强（已实现的六种上传 / 下载入口）、锁支持（写锁闭环 + 0.2.0 补齐的共享锁 / `If` / lock-null / 423 重试）、P0 协议正确性缺口的逐条对照、P1 能力扩展候选、P2 远期方向；业界对标**未联网核实** |
| [04-ci-cd.md](04-ci-cd.md) | CI / CD：测试与发布工作流 | `.github/workflows/` 两套工作流的触发条件与逐步职责、门禁含义（`.mbti` / 格式）、e2e 与 `run_tests.sh` + python 兜底服务端的关系、`MOONCAKES_TOKEN` 一次性配置与发布四步流程、已知注意事项（仅 native、源码里的 `Int` 必须写成 `Int32`、`--dry-run` 退出码、`.moonignore` 不含 `src/main`） |
| [05-lock-extensions.md](05-lock-extensions.md) | 锁能力扩展 | 共享锁 `LockScope`、完整 `If` 头（BNF / 渲染规则 / 本地 400 校验）、lock-null 清理算法（RFC 4918 §7.3）、423 自动补令牌重试（开关、进程内注册表、可重放性、风险）、关键文件与测试矩阵、已知限制（`Depth: 1` 的 LOCK 不做等） |
