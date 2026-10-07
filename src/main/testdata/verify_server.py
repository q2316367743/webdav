#!/usr/bin/env python3
"""最小 WebDAV 验证服务器（run_tests.sh 的回退依赖）。

仅用于本地验证 MoonBit WebDAV 客户端：支持 OPTIONS/PUT/MKCOL/GET/HEAD/
DELETE/MOVE/COPY/PROPFIND/PROPPATCH，死属性存内存（每次启动清空）。
brew 版 `webdav`（hacdias）可用时优先用它，本脚本兜底——区别是本脚本
的 PROPPATCH 死属性真的能读回。

刻意对齐协议的几处细节（用于验证客户端的 P0 修复）：
- Depth:1 不递归（只回直接子项），Depth:infinity 才回整棵树；
- propname 只回属性名；按名请求时「没存过的死属性」回 404 propstat；
- 环境变量 VERIFY_NO_HEAD_PREFIX 命中前缀的 HEAD 返回 405，
  用来验证客户端的 HEAD → PROPFIND Depth:0 回落。

用法：python3 verify_server.py [port] [root]
默认：8083 /tmp/webdav-verify-root
"""
import os
import re
import shutil
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse
from xml.sax.saxutils import escape

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8083
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/webdav-verify-root"
DEAD_PROPS = {}  # 服务器路径 -> {属性名: 值}
NS_DEAD = "urn:q2316367743:webdav:prop"
NO_HEAD_PREFIX = os.environ.get("VERIFY_NO_HEAD_PREFIX", "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # 静默：测试输出只保留客户端侧日志

    # ---- 路径工具 ----
    def fs_path(self, url_path):
        rel = unquote(urlparse(url_path).path)
        return os.path.join(ROOT, rel.lstrip("/"))

    def dest_path(self):
        return self.fs_path(self.headers.get("Destination", ""))

    def send(self, status, body=b"", ctype="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        # HEAD 不发送响应体：长度也按 0 报，避免客户端按长度等待不存在的 body
        length = 0 if self.command == "HEAD" else len(body)
        self.send_header("Content-Length", str(length))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    # ---- 方法 ----
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Allow", "OPTIONS, GET, HEAD, PUT, MKCOL, DELETE, MOVE, COPY, PROPFIND, PROPPATCH")
        self.send_header("DAV", "1, 2")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(length)
        path = self.fs_path(self.path)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        self.send(201, b"")

    def do_MKCOL(self):
        path = self.fs_path(self.path)
        if os.path.exists(path):
            return self.send(405, b"exists")
        if not os.path.isdir(os.path.dirname(path)):
            return self.send(409, b"no parent")
        os.makedirs(path)
        self.send(201, b"")

    def do_GET(self):
        path = self.fs_path(self.path)
        if not os.path.isfile(path):
            return self.send(404, b"not found")
        with open(path, "rb") as f:
            self.send(200, f.read(), "application/octet-stream")

    def do_HEAD(self):
        if NO_HEAD_PREFIX and urlparse(self.path).path.startswith(NO_HEAD_PREFIX):
            return self.send(405, b"HEAD not supported for this prefix")
        if os.path.exists(self.fs_path(self.path)):
            self.send(200, b"")
        else:
            self.send(404, b"")

    def do_DELETE(self):
        path = self.fs_path(self.path)
        if os.path.isdir(path):
            shutil.rmtree(path)
            return self.send(204, b"")
        if os.path.isfile(path):
            os.remove(path)
            return self.send(204, b"")
        self.send(404, b"not found")

    def do_MOVE(self):
        src, dst = self.fs_path(self.path), self.dest_path()
        if not os.path.exists(src):
            return self.send(404, b"not found")
        if os.path.exists(dst) and self.headers.get("Overwrite", "T").upper() != "T":
            return self.send(412, b"precondition")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)
        self.send(201, b"")

    def do_COPY(self):
        src, dst = self.fs_path(self.path), self.dest_path()
        if not os.path.exists(src):
            return self.send(404, b"not found")
        if os.path.exists(dst) and self.headers.get("Overwrite", "T").upper() != "T":
            return self.send(412, b"precondition")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
        self.send(201, b"")

    def do_PROPFIND(self):
        path = self.fs_path(self.path)
        depth = self.headers.get("Depth", "1")
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        if not os.path.exists(path):
            return self.send(404, b"not found")
        entries = [self.path]
        if depth != "0":
            entries += self._children(self.path, path)
        self.send(207, self._multistatus(entries, body).encode(), "application/xml; charset=utf-8")

    def _children(self, url_base, fs_dir):
        """Depth:1 只回直接子项；Depth:infinity 才递归整棵树。"""
        out = []
        base = urlparse(url_base).path.rstrip("/")
        for name in sorted(os.listdir(fs_dir)):
            child_fs = os.path.join(fs_dir, name)
            suffix = "/" if os.path.isdir(child_fs) else ""
            out.append(base + "/" + name + suffix)
            if self.headers.get("Depth") == "infinity" and os.path.isdir(child_fs):
                out.extend(self._children(base + "/" + name, child_fs))
        return out

    def _live_props(self, url_path):
        """活属性：[(限定名, 值的 XML 片段)]。"""
        path = self.fs_path(url_path)
        is_dir = os.path.isdir(path)
        props = [("D:resourcetype", "<D:collection/>" if is_dir else "")]
        if not is_dir and os.path.isfile(path):
            props.append(("D:getcontentlength", "%d" % os.path.getsize(path)))
            props.append(("D:getcontenttype", "application/octet-stream"))
            props.append(("D:getlastmodified", time.strftime(
                "%a, %d %b %Y %H:%M:%S GMT", time.gmtime(os.path.getmtime(path)))))
        return props

    def _propstats(self, url_path, mode, names):
        """按状态码分段：命中 200，请求了但没存过的死属性 404。"""
        dead = DEAD_PROPS.get(urlparse(url_path).path, {})
        ok, missing = [], []
        if mode == "named":
            for name in names:
                if name in dead:
                    ok.append('<X:%s xmlns:X="%s">%s</X:%s>' % (name, NS_DEAD, escape(dead[name]), name))
                else:
                    missing.append('<X:%s xmlns:X="%s"/>' % (name, NS_DEAD))
        else:
            for tag, value in self._live_props(url_path):
                ok.append("<%s>%s</%s>" % (tag, value, tag))
            for name, value in dead.items():
                # propname 只要名字（值留空）
                body = "" if mode == "propname" else escape(value)
                ok.append('<X:%s xmlns:X="%s">%s</X:%s>' % (name, NS_DEAD, body, name))
        parts = []
        if ok:
            parts.append("<D:propstat><D:prop>%s</D:prop>"
                         "<D:status>HTTP/1.1 200 OK</D:status></D:propstat>" % "".join(ok))
        if missing:
            parts.append("<D:propstat><D:prop>%s</D:prop>"
                         "<D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>" % "".join(missing))
        return parts

    def _multistatus(self, url_paths, body=""):
        if "<D:propname" in body or "<propname" in body:
            mode, names = "propname", []
        elif "<D:prop>" in body or "<prop>" in body:
            mode = "named"
            names = re.findall(r"<[A-Za-z_][\w.-]*:([A-Za-z_][\w.-]*)\s*/>", body)
        else:
            mode, names = "allprop", []
        parts = ['<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">']
        for url_path in url_paths:
            parts.append("<D:response>")
            parts.append("<D:href>%s</D:href>" % escape(urlparse(url_path).path))
            parts.extend(self._propstats(url_path, mode, names))
            parts.append("</D:response>")
        parts.append("</D:multistatus>")
        return "".join(parts)

    def do_PROPPATCH(self):
        length = int(self.headers.get("Content-Length", 0))
        xml_body = self.rfile.read(length).decode("utf-8")
        url_path = urlparse(self.path).path
        dead = DEAD_PROPS.setdefault(url_path, {})
        for name, value in re.findall(r"<X:([^>]+)>([^<]*)</X:\1>", xml_body):
            dead[name] = value
        resp = ('<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response>'
                "<D:href>%s</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status>"
                "</D:propstat></D:response></D:multistatus>" % escape(url_path))
        self.send(207, resp.encode(), "application/xml; charset=utf-8")


if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("WebDAV verify server on http://127.0.0.1:%d/ root=%s" % (PORT, ROOT), flush=True)
    server.serve_forever()
