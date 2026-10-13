// 锁相关演示：独占锁闭环 + P1 锁能力扩展（共享锁、带标签 `If`、
// lock-null 清理、423 自动补令牌重试）。
// 所有可选能力在服务端不支持时按中文说明软跳过，不计失败；
// 返回未通过的步骤标签，由 main 汇总。

///|
/// 跑一遍锁演示。`base_url` 用于再造一个开启 `retry_on_423` 的客户端
/// （423 自动重试是客户端开关，不影响原有客户端的行为）。
async fn demo_lock(
  client : @webdav.WebdavClient,
  base_url : String,
) -> Array[String] {
  let failures : Array[String] = []
  fn check(ok : Bool, step : String) -> Unit {
    if ok {
      println("✓ \{step}")
    } else {
      println("✗ \{step}")
      failures.push(step)
    }
  }
  // 可选能力的软跳过：状态码说明服务端不支持（或只认无标签 If）时
  // 只打印中文说明，不计失败
  fn optional_failure(step : String, error : @webdav.WebdavError) -> Unit {
    let text = error.to_string()
    for code in ["403", "404", "405", "409", "412", "501"] {
      if text.contains(code) {
        println("（服务端不支持该能力，跳过 \{step}：\{error}）")
        return
      }
    }
    check(false, step)
  }
  let locked_path = "/demo/locked.txt"
  let shared_path = "/demo/shared.txt"
  let retry_path = "/demo/retry.txt"
  // 1. 独占锁闭环
  let _ = client.put_file(
    path=locked_path,
    data=@utf8.encode("锁前写入"),
    content_type="text/plain; charset=utf-8",
  )
  let locked = client.lock(
    path=locked_path,
    owner="demo@example.com",
    timeout="Second-300",
  )
  let token = locked.lock.token
  check(token != "", "LOCK \{locked_path}（令牌 \{token}）")
  let blocked = try {
    let _ = client.put_file(
      path=locked_path,
      data=@utf8.encode("无令牌写入"),
      content_type="text/plain; charset=utf-8",
    )
    false
  } catch {
    error => {
      println("  无令牌 PUT 被拒：\{error}")
      error.to_string().contains("423")
    }
  }
  check(blocked, "无锁令牌的 PUT 被拒（423）")
  let write = client.put_file(
    path=locked_path,
    data=@utf8.encode("带令牌写入"),
    content_type="text/plain; charset=utf-8",
    conditions=@webdav.Conditions::new(lock_token=token),
  )
  println("✓ 带锁令牌 PUT（HTTP \{write.status}）")
  let refreshed = client.refresh_lock(
    path=locked_path,
    token~,
    timeout="Second-600",
  )
  check(refreshed.status == 200, "刷新锁（Timeout → Second-600）")
  let locks = client.get_locks(path=locked_path)
  if locks.is_empty() {
    println(
      "（服务端 PROPFIND 不回 lockdiscovery，跳过锁发现校验）",
    )
  } else {
    check(
      locks[0].token != "",
      "PROPFIND lockdiscovery（\{locks.length()} 把锁）",
    )
  }
  // 2. 带标签 If（RFC 4918 §10.4.2 的 Tagged-list）
  let tagged = try {
    let _ = client.put_file(
      path=locked_path,
      data=@utf8.encode("带标签 If 写入"),
      content_type="text/plain; charset=utf-8",
      conditions=@webdav.Conditions::new(if_lists=[
        @webdav.IfList::new(
          [@webdav.IfCondition::token(token)],
          resource_tag=locked_path,
        ),
      ]),
    )
    println("✓ 带标签 If（Tagged-list）写请求通过")
    true
  } catch {
    error => {
      optional_failure("带标签 If（Tagged-list）", error)
      true
    }
  }
  ignore(tagged)
  client.unlock(path=locked_path, token~)
  println("✓ UNLOCK \{locked_path}")
  // 3. 共享锁：两个共享锁可以共存，独占锁与任何锁互斥
  let _ = client.put_file(
    path=shared_path,
    data=@utf8.encode("共享锁演示"),
    content_type="text/plain; charset=utf-8",
  )
  let mut shared_token : String? = None
  let shared_done = try {
    let shared = client.lock(
      path=shared_path,
      scope=@webdav.LockScope::Shared,
      owner="demo@example.com",
      timeout="Second-300",
    )
    shared_token = Some(shared.lock.token)
    match shared.lock.scope {
      @webdav.LockScope::Shared =>
        println("✓ 共享锁（令牌 \{shared.lock.token}）")
      @webdav.LockScope::Exclusive =>
        println(
          "（服务端把共享锁按独占回填，仍算 LOCK 成功）",
        )
    }
    true
  } catch {
    error => {
      optional_failure("共享锁", error)
      true
    }
  }
  ignore(shared_done)
  match shared_token {
    Some(value) =>
      client.unlock(path=shared_path, token=value) catch {
        error => println("（共享锁释放失败：\{error}）")
      }
    None => ()
  }
  // 4. lock-null：锁定不存在的路径时服务端会创建空资源，锁消失后按 §7.3 清理。
  // 路径刻意放在根目录：run_tests.sh 让 /demo 下的 HEAD 回 405（验证 exists
  // 的 PROPFIND 回落），而清理要靠 HEAD 的 Content-Length 判断资源是空的。
  let null_path = "/lock-null-demo.txt"
  let null_done = try {
    let created = client.lock(path=null_path, timeout="Second-300")
    if created.created {
      check(
        client.cleanup_lock_null(path=null_path, token=created.lock.token),
        "lock-null 清理（\{null_path}）",
      )
      check(!client.exists(path=null_path), "lock-null 资源已删除")
    } else {
      client.unlock(path=null_path, token=created.lock.token)
      println(
        "（服务端 LOCK 未映射路径时未创建资源（HTTP \{created.status}），跳过 lock-null 清理）",
      )
    }
    true
  } catch {
    error => {
      optional_failure("lock-null（锁定不存在的路径）", error)
      true
    }
  }
  ignore(null_done)
  // 5. 423 自动补令牌重试：同一个客户端自己加锁后再写，无需手工传令牌
  let retry_client = @webdav.create_webdav_client({
    base_url,
    username: @env.get_env_var("WEBDAV_USER"),
    password: @env.get_env_var("WEBDAV_PASS"),
    timeout_ms: Some(10_000),
    retry_on_423: Some(true),
  })
  let retry_done = try {
    let _ = client.put_file(
      path=retry_path,
      data=@utf8.encode("重试前写入"),
      content_type="text/plain; charset=utf-8",
    )
    let held = retry_client.lock(
      path=retry_path,
      owner="demo@example.com",
      timeout="Second-300",
    )
    let retried = retry_client.put_file(
      path=retry_path,
      data=@utf8.encode("自动补令牌写入"),
      content_type="text/plain; charset=utf-8",
    )
    check(
      retried.status == 200 || retried.status == 201,
      "423 自动补令牌重试（HTTP \{retried.status}）",
    )
    retry_client.unlock(path=retry_path, token=held.lock.token)
    true
  } catch {
    error => {
      optional_failure("423 自动重试", error)
      true
    }
  }
  ignore(retry_done)
  // 6. 收尾：清掉演示产生的文件（失败只提示，不改变前面的结论）
  for path in [locked_path, shared_path, retry_path] {
    client.delete(path~) catch {
      error => println("（清理 \{path} 失败：\{error}）")
    }
  }
  failures
}
