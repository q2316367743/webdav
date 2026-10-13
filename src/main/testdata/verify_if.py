#!/usr/bin/env python3
"""`If` 头解析（RFC 4918 §10.4.2–§10.4.4 的兜底子集）。

兜底服务端只需要回答一个问题：本次请求为某个资源提交了哪些状态令牌。
为此只需要一个够用的解析器：

- `(<条件> …)` 是无标签列表，作用于请求 URI；`</url> (<条件> …)` 是带标签
  列表，作用于资源标签指向的 URL（标签是资源位置，**不是**令牌）；
- 条件是 `<令牌>`（状态令牌）或 `[etag]`，可带 `Not ` 前缀，`Not` 只否定
  紧随其后的那一条；列表内合取、列表之间析取；
- 解析不出任何列表时退化为「头里所有 `<...>` 都算令牌」，兼容老客户端。

刻意不做完整求值：ETag 比较与 `Not` 的存在性判定对本验证服务器没有意义，
只要不把资源标签和 `Not` 掉的令牌误当成「已提交的令牌」即可。
"""
from urllib.parse import urlparse

import re

# `</url> (<条件>)` 或 `(<条件>)`：资源标签可选，注意非贪婪地只取一对括号
LIST_RE = re.compile(r"(?:<([^>]*)>\s*)?\(([^)]*)\)")
# 单条条件：可选的 `Not ` + `<令牌>` 或 `[etag]`
COND_RE = re.compile(r"(Not\s+)?(?:<([^>]*)>|\[([^\]]*)\])")
# 退化模式下笼统取出的 `<...>`（无法解析列表时才用）
ANY_ANGLE_RE = re.compile(r"<([^>]*)>")


def parse_if(header):
    """解析成 `[(resource_tag, [(negated, kind, value)])]`；解析不出返回 `[]`。

    `resource_tag` 为 `None` 表示无标签列表；`kind` 取 `"token"` 或 `"etag"`。
    """
    lists = []
    current_tag = None  # Resource-Tag 对其后所有没有自己标签的 List 都生效
    for match in LIST_RE.finditer(header or ""):
        if match.group(1) is not None:
            current_tag = match.group(1)
        conditions = []
        for cond in COND_RE.finditer(match.group(2)):
            negated = bool(cond.group(1))
            if cond.group(2) is not None:
                conditions.append((negated, "token", cond.group(2)))
            else:
                conditions.append((negated, "etag", cond.group(3)))
        lists.append((current_tag, conditions))
    return lists


def _same_resource(tag, path):
    """资源标签与请求路径是否指向同一资源（标签可能是完整 URL）。"""
    return urlparse(tag).path.rstrip("/") == (path or "").rstrip("/")


def submitted_tokens(header, path=None):
    """请求针对 `path` 提交的状态令牌集合。

    带标签列表只在其资源标签指向 `path` 时生效；`Not <令牌>` 表示「该令牌
    必须不存在」，不作为已提交的令牌返回。解析不出任何列表时退化为
    「头里所有 `<...>` 都算令牌」（老客户端与手工构造的请求）。
    """
    lists = parse_if(header)
    if not lists:
        return set(ANY_ANGLE_RE.findall(header or ""))
    tokens = set()
    for tag, conditions in lists:
        if tag is not None and path is not None and not _same_resource(tag, path):
            continue
        for negated, kind, value in conditions:
            if kind == "token" and not negated:
                tokens.add(value)
    return tokens
