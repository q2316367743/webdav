#!/usr/bin/env python3
"""内存锁表与 LOCK/UNLOCK 处理器：verify_server.py 的锁支撑。

刻意与 hacdias/webdav 互补：令牌带 `opaquelocktoken:` 前缀（hacdias 用裸数字），
`Lock-Token` 与 `If` 里的令牌都要求尖括号包裹（RFC 4918 §10.4.1 的 Coded-URL）。

`LockMixin` 是 HTTP 处理器的混入：宿主类需提供 `send`、`fs_path`、
`path`、`headers`、`rfile` 与 `BaseHTTPRequestHandler` 的响应方法。
"""
import os
import random
import re
from urllib.parse import urlparse
from xml.sax.saxutils import escape

DEFAULT_TIMEOUT = "Second-3600"


class LockTable:
    """路径 -> 锁；同一路径只保留最后一把锁（重复加锁由调用方判 423）。"""

    def __init__(self):
        self._locks = {}

    def lock(self, path, owner="", timeout=None, depth="infinity"):
        token = "opaquelocktoken:%08x" % random.getrandbits(32)
        while self.find_by_token(token):  # 令牌全局唯一
            token = "opaquelocktoken:%08x" % random.getrandbits(32)
        entry = {
            "token": token,
            "path": path,
            "owner": owner or "",
            "timeout": timeout or DEFAULT_TIMEOUT,
            "depth": depth,
            "lockroot": path,
        }
        self._locks[path] = entry
        return entry

    def all(self):
        return list(self._locks.values())

    def find_by_token(self, token):
        for entry in self._locks.values():
            if entry["token"] == token:
                return entry
        return None

    def find_by_path(self, path):
        entry = self._locks.get(path)
        return [entry] if entry else []

    def find_by_tokens(self, tokens):
        for token in tokens:
            entry = self.find_by_token(token)
            if entry:
                return entry
        return None

    def refresh(self, entry, timeout=None):
        if timeout:
            entry["timeout"] = timeout
        return entry

    def unlock(self, entry):
        self._locks.pop(entry["path"], None)


def covering_locks(table, path):
    """覆盖 path 的锁：自身锁，或 Depth:infinity 的祖先锁。"""
    prefix_hit = []
    for entry in table.all():
        if entry["path"] == path:
            return [entry]
        root = entry["path"].rstrip("/")
        if entry["depth"] == "infinity" and path.startswith(root + "/"):
            prefix_hit.append(entry)
    return prefix_hit


def if_tokens(header):
    """取出 If 头里所有 `<...>` 令牌（无标签与带标签列表都兼容）。"""
    return set(re.findall(r"<([^>]*)>", header or ""))


def _activelock(entry):
    owner = escape(entry["owner"]) if entry["owner"] else ""
    return (
        "<D:activelock><D:lockscope><D:exclusive/></D:lockscope>"
        "<D:locktype><D:write/></D:locktype><D:depth>%s</D:depth>"
        "<D:owner>%s</D:owner><D:timeout>%s</D:timeout>"
        "<D:locktoken><D:href>%s</D:href></D:locktoken>"
        "<D:lockroot><D:href>%s</D:href></D:lockroot></D:activelock>"
        % (
            entry["depth"],
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
        covering = covering_locks(LOCK_TABLE, urlparse(url_path).path)
        if not covering:
            return None
        tokens = if_tokens(self.headers.get("If", ""))
        return None if any(e["token"] in tokens for e in covering) else 423

    def _locked(self):
        """命中锁则直接回 423 并返回 True（调用方立刻 return）。"""
        code = self._lock_check(self.path)
        if code:
            self.send(code, b"locked")
        return code is not None

    def _lock_response(self, entry):
        body = lockdiscovery_xml([entry]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Lock-Token", "<%s>" % entry["token"])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_LOCK(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        url_path = urlparse(self.path).path
        if not body:
            # 无请求体 = 刷新：必须带匹配的 If 令牌
            entry = LOCK_TABLE.find_by_tokens(if_tokens(self.headers.get("If", "")))
            if entry is None or entry["path"] != url_path:
                return self.send(412, b"precondition")
            return self._lock_response(
                LOCK_TABLE.refresh(entry, self.headers.get("Timeout")))
        if not os.path.exists(self.fs_path(self.path)):
            return self.send(404, b"not found")  # 不实现 lock-null 创建
        covering = covering_locks(LOCK_TABLE, url_path)
        if covering:
            tokens = if_tokens(self.headers.get("If", ""))
            if not any(e["token"] in tokens for e in covering):
                return self.send(423, b"locked")
            return self._lock_response(covering[0])
        owner = re.findall(r"<D:owner>(.*?)</D:owner>", body, re.S)
        entry = LOCK_TABLE.lock(
            url_path, owner[0] if owner else "", self.headers.get("Timeout"))
        self._lock_response(entry)

    def do_UNLOCK(self):
        token = (self.headers.get("Lock-Token") or "").strip("<>")
        if not token:
            return self.send(400, b"missing Lock-Token")
        entry = LOCK_TABLE.find_by_token(token)
        if entry is None or entry["path"] != urlparse(self.path).path:
            return self.send(409, b"no such lock")
        LOCK_TABLE.unlock(entry)
        self.send(204, b"")
