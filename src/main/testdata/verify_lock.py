#!/usr/bin/env python3
"""内存锁表与 LOCK/UNLOCK 处理器：verify_server.py 的锁支撑。

刻意与 hacdias/webdav 互补：令牌带 `opaquelocktoken:` 前缀（hacdias 用裸数字），
`Lock-Token` 与 `If` 里的令牌都要求尖括号包裹（RFC 4918 §10.4.1 的 Coded-URL）。

覆盖的能力：
- 同一路径可以有多把**共享锁**（shared 之间共存，独占锁与任何锁互斥）；
- LOCK 响应体按锁的实际作用域回 `<D:shared/>` 或 `<D:exclusive/>`；
- 对不存在的路径加锁时创建空资源并回 **201**（RFC 4918 §7.3 的 lock-null）；
- `If` 头交给 verify_if.submitted_tokens 解析（带标签列表、`Not`、`[etag]`）。

`LockMixin` 是 HTTP 处理器的混入：宿主类需提供 `send`、`fs_path`、
`path`、`headers`、`rfile` 与 `BaseHTTPRequestHandler` 的响应方法。
"""
import os
import random
import re
from urllib.parse import urlparse
from xml.sax.saxutils import escape

from verify_if import submitted_tokens

DEFAULT_TIMEOUT = "Second-3600"


class LockTable:
    """路径 -> 锁列表；共享锁可共存，独占锁与任何锁互斥（RFC 4918 §6.1）。"""

    def __init__(self):
        self._locks = {}

    def add(self, path, scope="exclusive", owner="", timeout=None, depth="infinity"):
        token = "opaquelocktoken:%08x" % random.getrandbits(32)
        while self.find_by_token(token):  # 令牌全局唯一
            token = "opaquelocktoken:%08x" % random.getrandbits(32)
        entry = {
            "token": token,
            "path": path,
            "scope": "shared" if scope == "shared" else "exclusive",
            "owner": owner or "",
            "timeout": timeout or DEFAULT_TIMEOUT,
            "depth": depth or "infinity",
            "lockroot": path,
        }
        self._locks.setdefault(path, []).append(entry)
        return entry

    def all(self):
        return [entry for entries in self._locks.values() for entry in entries]

    def find_by_token(self, token):
        for entry in self.all():
            if entry["token"] == token:
                return entry
        return None

    def find_by_path(self, path):
        return list(self._locks.get(path, []))

    def find_by_tokens(self, tokens):
        for token in tokens:
            entry = self.find_by_token(token)
            if entry:
                return entry
        return None

    def conflicting(self, path, scope):
        """与 (path, scope) 冲突的已有锁：独占对任何锁冲突，共享只对独占冲突。"""
        return [
            entry
            for entry in self.find_by_path(path)
            if scope == "exclusive" or entry["scope"] == "exclusive"
        ]

    def refresh(self, entry, timeout=None):
        if timeout:
            entry["timeout"] = timeout
        return entry

    def unlock(self, entry):
        remain = [
            other
            for other in self.find_by_path(entry["path"])
            if other["token"] != entry["token"]
        ]
        if remain:
            self._locks[entry["path"]] = remain
        else:
            self._locks.pop(entry["path"], None)


def covering_locks(table, path):
    """覆盖 path 的锁：同路径的锁，或 Depth:infinity 的祖先锁（可有多把）。"""
    hit = []
    for entry in table.all():
        root = entry["path"].rstrip("/")
        if entry["path"] == path or (
            entry["depth"] == "infinity" and path.startswith(root + "/")
        ):
            hit.append(entry)
    return hit


def _activelock(entry):
    owner = escape(entry["owner"]) if entry["owner"] else ""
    scope = "shared" if entry["scope"] == "shared" else "exclusive"
    return (
        "<D:activelock><D:lockscope><D:%s/></D:lockscope>"
        "<D:locktype><D:write/></D:locktype><D:depth>%s</D:depth>"
        "<D:owner>%s</D:owner><D:timeout>%s</D:timeout>"
        "<D:locktoken><D:href>%s</D:href></D:locktoken>"
        "<D:lockroot><D:href>%s</D:href></D:lockroot></D:activelock>"
        % (
            scope,
            escape(entry["depth"]),
            owner,
            escape(entry["timeout"]),
            escape(entry["token"]),
            escape(entry["lockroot"]),
        )
    )


def lockdiscovery_xml(locks):
    return "<D:lockdiscovery>%s</D:lockdiscovery>" % "".join(
        _activelock(entry) for entry in locks
    )


LOCK_TABLE = LockTable()


class LockMixin:
    """LOCK / UNLOCK 与写方法的 423 前置校验。"""

    def _lock_check(self, url_path):
        """写方法前置：被锁且请求未带匹配令牌时返回 423，否则 None。"""
        path = urlparse(url_path).path
        covering = covering_locks(LOCK_TABLE, path)
        if not covering:
            return None
        tokens = submitted_tokens(self.headers.get("If", ""), path)
        return None if any(e["token"] in tokens for e in covering) else 423

    def _locked(self):
        """命中锁则直接回 423 并返回 True（调用方立刻 return）。"""
        code = self._lock_check(self.path)
        if code:
            self.send(code, b"locked")
        return code is not None

    def _lock_response(self, entry, status=200):
        body = lockdiscovery_xml([entry]).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Lock-Token", "<%s>" % entry["token"])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_LOCK(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        url_path = urlparse(self.path).path
        tokens = submitted_tokens(self.headers.get("If", ""), url_path)
        if not body:
            # 无请求体 = 刷新：必须提交该资源上的锁令牌
            entry = LOCK_TABLE.find_by_tokens(tokens)
            if entry is None or entry["path"] != url_path:
                return self.send(412, b"precondition")
            return self._lock_response(
                LOCK_TABLE.refresh(entry, self.headers.get("Timeout"))
            )
        scope = "shared" if re.search(r"<D:shared\s*/>", body) else "exclusive"
        conflicts = LOCK_TABLE.conflicting(url_path, scope)
        if conflicts:
            if not any(e["token"] in tokens for e in conflicts):
                return self.send(423, b"locked")
            # 客户端已持有冲突锁：沿用第一把，不新建
            return self._lock_response(conflicts[0])
        status = 200
        if not os.path.exists(self.fs_path(self.path)):
            # lock-null：为不存在的路径创建空资源后再加锁（RFC 4918 §7.3）
            fs_path = self.fs_path(self.path)
            if not os.path.isdir(os.path.dirname(fs_path)):
                return self.send(409, b"missing parent")
            with open(fs_path, "wb"):
                pass
            status = 201
        owner = re.findall(r"<D:owner>(.*?)</D:owner>", body, re.S)
        entry = LOCK_TABLE.add(
            url_path,
            scope,
            owner[0] if owner else "",
            self.headers.get("Timeout"),
            self.headers.get("Depth"),
        )
        self._lock_response(entry, status)

    def do_UNLOCK(self):
        token = (self.headers.get("Lock-Token") or "").strip("<>")
        if not token:
            return self.send(400, b"missing Lock-Token")
        entry = LOCK_TABLE.find_by_token(token)
        if entry is None or entry["path"] != urlparse(self.path).path:
            return self.send(409, b"no such lock")
        LOCK_TABLE.unlock(entry)
        self.send(204, b"")
