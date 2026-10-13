# 05 锁能力扩展：共享锁、`If` 头、lock-null 清理与 423 重试

对应 `docs/03-gap-analysis.md` 的 P1 第 7 条「锁能力扩展」。基线是 0.1.0 已交付的
**独占写锁闭环**（`lock` / `refresh_lock` / `unlock` / `get_locks`），0.2.0 在其上补齐：

| 能力 | 结论 |
|------|------|
| 共享锁（`<D:shared/>`） | 已实现：`LockScope` + 请求体 / 响应解析 |
| 带标签 `If`、`Not`、`[etag]`、多令牌 | 已实现：`IfList` / `IfCondition` + 渲染器 |
| lock-null 的创建清理 | 已实现：`cleanup_lock_null`（服务端创建的资源由客户端收尾） |
| 按 423 自动补令牌重试 | 已实现：`WebdavConfig.retry_on_423`（默认关） |
| `Depth: 1` 的 LOCK | **不做**：RFC 4918 §9.10.3 规定 Depth 只能是 0 或 infinity，本层继续本地拦 `Api(400)` |
| 跨进程锁共享、5xx/断线退避重试 | 不做（见 §7） |

对外输出、错误文案与类型注释一律中文；`ActiveLock.scope` 由 `String` 变为
枚举属于**破坏性变更**（0.1.x → 0.2.0，moon.mod 版本号已同步）。

---

## 1. 作用域：`LockScope`

`src/types/lock.mbt`：

```moonbit
pub(all) enum LockScope { Exclusive; Shared }
pub fn LockScope::to_dav(self) -> String            // "exclusive" / "shared"
pub fn LockScope::from_dav(name : String) -> LockScope  // trim + 大小写不敏感，未知 → Exclusive
```

契约：

- `lockinfo_body(owner?, scope?)` 省略 `scope` 时仍发 `<D:exclusive/>`（向后兼容）；
- `parse_lockdiscovery(xml_text, default_scope?)` **以服务端为准**：响应体里的
  `<D:lockscope>` 优先；服务端没回时用 `default_scope`（`lock()` 传请求的作用域，
  `refresh_lock` 不传 → `Exclusive`）；
- `WebdavClient::lock(..., scope?)` 省略即独占锁。hacdias 5.x 对共享锁回 `501`，
  演示程序会软跳过而不是记失败；
- **令牌来源**：`lock` 优先取响应头 `Lock-Token`，其次响应体首个 `activelock`；
  两者都没有才抛 `Api(operation="LOCK", message="响应缺少锁令牌…")`（响应体 XML 非法
  但有 `Lock-Token` 头时仍算成功）；
- **状态码**：UNLOCK 令牌不匹配 → `409`、刷新锁缺少匹配的 `If` → `412`、被锁资源上
  无令牌的写操作 → `423`，都映射为 `Api`（不做本地预判）；
- **锁发现**：`get_locks` 用 `Depth:0` 的 PROPFIND 读 `lockdiscovery`，服务端没实现时
  返回空数组（hacdias 只回空元素，Python 兜底服务器能读回）。

## 2. `If` 头（RFC 4918 §10.4.2–§10.4.4）

结构（`src/types/protocol.mbt`）：

```moonbit
pub(all) enum IfConditionKind { StateToken; EntityTag }
pub(all) struct IfCondition { kind : IfConditionKind; value : String; negated : Bool }
pub(all) struct IfList { resource_tag : String?; conditions : Array[IfCondition] }
// Conditions 新增第 4 个字段
pub(all) struct Conditions { if_match : String?; if_none_match : String?; lock_token : String?; if_lists : Array[IfList] }
```

渲染器在 `src/client/if_header.mbt`，`apply_conditions` 只在渲染结果非空时才设置 `If`：

| 输入 | 渲染结果 |
|------|----------|
| `if_lists=[IfList::new([token("<t1>"), etag("\"v1\"")])]` | `(<t1> ["v1"])` |
| `IfCondition::token("<t1>", negated=true)` | `Not <t1>` |
| `IfList::new([...], resource_tag="/dir")` | `</dir> (<t1>)` |
| 带标签列表 + `lock_token="<t2>"` | `</dir> (<t1>) (<t2>)`（`lock_token` 追加为无标签列表） |
| 无标签列表 + `lock_token` | `(<t1>) (<t2>)`（列表之间空格连接 = 析取） |
| 令牌归一化后为空 | 本地 `Api(400)`，**不发请求** |

本地校验（全部在发请求前，`operation` 沿用调用方法名）：

- 无标签列表与带标签列表混用 → 「If 头的无标签列表与带标签列表不能混用」；
- 列表里一个条件都没有 → 「If 列表至少要有一个条件」；
- `resource_tag=Some("")` → 「If 列表的资源标签不能为空」；
- 状态令牌只写了尖括号或空白 → 「If 条件里的锁令牌不能为空」。

客户端**只负责渲出合法的 `If`**，求值（列表内合取、列表间析取、正则匹配）由服务端做；
`Not` / `[etag]` 的取值语义见 RFC §10.4.3–§10.4.4，本层不做本地预判。

## 3. lock-null 清理：`cleanup_lock_null`

RFC 4918 §7.3：LOCK 未映射的路径时服务端会创建**空资源**，而该资源在锁消失后
**SHOULD NOT** 自动删除（「clients must therefore be responsible for cleaning up their
own mess」）。`WebdavClient::cleanup_lock_null(path~, token~, signal?) -> Bool` 封装这段收尾：

1. `unlock(path, token)`；`404` / `409`（锁已消失）视为继续，其他错误原样上抛；
2. `HEAD` 探测资源：`404` → 资源不存在，返回 `false`（无锁可释放，也没什么可删）；
3. 只有 `Content-Length` 明确为 `0` 才继续；长度非 0、或服务端没给长度（`HEAD` 405/501
   回退 `PROPFIND` 时长度未知）一律返回 `false`，**绝不误删有内容的资源**；
4. 有 `ETag` 时用 `If-Match` 条件 `DELETE`，最后返回 `true`。

返回值语义：`true` = 已确认删除空资源；`false` = 资源不空 / 长度未知 / 本就不是 lock-null。

## 4. 423 自动补令牌重试

开关：`WebdavConfig.retry_on_423 : Bool?`（`None` / `false` = 关闭，保持 0.1.0 的
「客户端不自动重试、不自动加锁」契约）。

已知锁注册表（`src/client/lock_registry.mbt`，进程内缓存）：

```moonbit
priv struct KnownLock { token : String; path : String; depth : String? }
```

- `lock` / `refresh_lock` 成功后 `remember_lock`；`unlock` 成功后 `forget_lock`；
- 同 `(token, path)` 去重；最多 `256` 条，超限淘汰最旧；
- `covering_lock_token(path)` 从最新往旧扫，命中「同一路径」或「`depth == "infinity"`
  的祖先路径」就返回令牌；
- 路径比较前先规范化（压掉重复 `/`，保留一个规范前导 `/`）；
- 服务端响应没回 `<D:depth>` 时，用**请求里声明的 Depth** 兜底（`declared_depth`），
  否则祖先锁会丢失覆盖范围。

重试规则（`WebdavClient::send`）：

- 仅当响应为 `423`、开关打开、且注册表能给出覆盖该路径的令牌时，**恰好重试一次**
  （原 `Conditions` 复制一份并 `with_lock_token`，`If-Match` / `if_lists` 等条件全部保留）；
- 只针对**请求 URI 自己**的锁：`MOVE` / `COPY` 的目标被锁不重试（目标不是本次请求的
  `path`，目标锁需要显式传令牌）；
- 可重放性决定谁能重试：`put_file`（体内存里的 `BytesReader` 可重置）可重试；
  `put_file_stream` / `put_file_from_path` 的 `rewind? = None`，不参与重试；
- 注册表不代表服务端真实状态：别的客户端加锁、服务端重启、条目被 256 条上限淘汰时
  都会 miss，此时行为与 0.1.0 一致——把 `423` 抛给调用方。

## 5. 关键文件

| 文件 | 职责 |
|------|------|
| `src/types/lock.mbt` | `LockScope`、`ActiveLock.scope`、`LockResult`、令牌归一 |
| `src/types/protocol.mbt` | `IfConditionKind` / `IfCondition` / `IfList`、`Conditions`（含 `with_lock_token`） |
| `src/types/types.mbt` | `WebdavConfig.retry_on_423` |
| `src/client/if_header.mbt` | `If` 头渲染与本地校验、`lock_token_uri` / `lock_token_if_value` |
| `src/client/lock_registry.mbt` | 已知锁注册表、`covering_lock_token`、路径规范化 |
| `src/client/lock_ops.mbt` | `lock` / `refresh_lock` / `unlock` / `get_locks`、`check_lock_depth` |
| `src/client/lock_parse.mbt` | lockdiscovery 解析与 `Lock-Token` / `Timeout` 兜底 |
| `src/client/lock_cleanup.mbt` | `cleanup_lock_null` 与 `HEAD` 探测 |
| `src/client/client.mbt` | `build_config` / `perform` / `apply_conditions`、423 重试分支 |
| `src/xmlutil/lockinfo.mbt` | `lockinfo_body(owner?, scope?)`、`parse_lockdiscovery(..., default_scope?)` |
| `src/main/lock_demo.mbt` | e2e 演示：独占 / 共享 / 带标签 `If` / lock-null / 423 重试（不支持则软跳过） |
| `src/main/testdata/verify_if.py` | 兜底服务端的 `If` 解析子集 |
| `src/main/testdata/verify_lock.py` | 兜底服务端锁表：多把共享锁、scope 回传、lock-null 201 |

## 6. 测试与验证

- 单元 / 黑盒（`moon test`，共 139 例）：`src/types/lock_wbtest.mbt`、`src/client/if_header_test.mbt`、
  `lock_scope_test.mbt`、`lock_retry_test.mbt`、`lock_cleanup_test.mbt`、`lock_registry_wbtest.mbt`、
  `src/xmlutil/lockinfo_wbtest.mbt`；
- e2e（`bash src/main/run_tests.sh`）：阶段 1 `moon test`，阶段 2 `moon run src/main`；
- 两套服务端都跑过：python 兜底（`verify_server.py`，共享锁 / 带标签 `If` / lock-null 201 / 423 重试全部真实通过）
  与 brew `webdav`（hacdias 5.x：共享锁 `501`、带标签 `If` `412`、PROPFIND 不回 `lockdiscovery` — 均按预期软跳过，
  lock-null 与 423 重试通过）。

## 7. 已知限制

- **`Depth: 1` 的 LOCK 不做**：RFC 4918 §9.10.3 明确「Values other than 0 or infinity
  MUST NOT be used with the Depth header on a LOCK method」，本地继续回 `Api(400)`；
- **不自动退避重试** `5xx` / 连接重置（`docs/03-gap-analysis.md` 的 P2）；
- 注册表**不跨进程 / 不持久化**，只服务于「同一个客户端自己加锁后自己写」这一场景；
- lock-null 清理只认 `Content-Length: 0`，服务端不回长度时不删（安全优先）；
- `If` 头的 `[etag]` 与 `Not` 只做语法渲染，不做本地求值。
