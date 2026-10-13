// 锁作用域与条件请求扩容的白盒用例：`LockScope` 的 DAV 名互转、
// `If` 列表 / 条件构造、`Conditions::with_lock_token` 的拷贝语义。

///|
test "LockScope 的 DAV 元素名互转" {
  assert_eq(LockScope::Exclusive.to_dav(), "exclusive")
  assert_eq(LockScope::Shared.to_dav(), "shared")
  assert_true(LockScope::from_dav("shared") is LockScope::Shared)
  assert_true(LockScope::from_dav("Shared") is LockScope::Shared)
  assert_true(LockScope::from_dav("  SHARED  ") is LockScope::Shared)
}

///|
test "未知或缺失的 lockscope 一律按独占处理" {
  assert_true(LockScope::from_dav("exclusive") is LockScope::Exclusive)
  assert_true(LockScope::from_dav("") is LockScope::Exclusive)
  assert_true(LockScope::from_dav("Unknown") is LockScope::Exclusive)
}

///|
test "If 条件的构造：状态令牌与 ETag 各自成形" {
  let token = IfCondition::token("<opaquelocktoken:1>")
  assert_true(token.kind is IfConditionKind::StateToken)
  assert_eq(token.value, "<opaquelocktoken:1>")
  assert_false(token.negated)
  let negated = IfCondition::token("tok", negated=true)
  assert_true(negated.negated)
  let etag = IfCondition::etag("\"abc\"")
  assert_true(etag.kind is IfConditionKind::EntityTag)
  assert_eq(etag.value, "\"abc\"")
}

///|
test "If 列表默认无资源标签" {
  let list = IfList::new([IfCondition::token("tok")])
  assert_eq(list.conditions.length(), 1)
  assert_eq(list.resource_tag, None)
  let tagged = IfList::new([IfCondition::token("tok")], resource_tag="/a.txt")
  assert_eq(tagged.resource_tag, Some("/a.txt"))
}

///|
test "Conditions::new 省略 if_lists 时得到空数组" {
  let conditions = Conditions::new()
  assert_eq(conditions.if_lists.length(), 0)
  assert_eq(conditions.lock_token, None)
}

///|
test "Conditions::with_lock_token 只换令牌，其余字段保持不变" {
  let original = Conditions::new(if_match="\"1\"", if_lists=[
    IfList::new([IfCondition::etag("\"2\"")]),
  ])
  let updated = original.with_lock_token("tok-9")
  assert_eq(updated.lock_token, Some("tok-9"))
  assert_eq(updated.if_match, Some("\"1\""))
  assert_eq(updated.if_lists.length(), 1)
  // 原对象不受影响（返回值是新结构体）
  assert_eq(original.lock_token, None)
}
