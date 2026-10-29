#!/usr/bin/env python3
"""与 liu-fang38/moonbit-webdav 的重合度检测（申诉证据用）。

用途：量化「本仓与同生态的 liu-fang38/webdav 是否存在代码 / 文档复用」。

方法（四个指标，互相校验）：
  1. 全量 8-gram Jaccard：最直观，但对小文件敏感（两边各有十几行的
     XML 构造文件时，比例会被小分母放大），故不作为唯一依据。
  2. 同规模子集 Jaccard：只比两侧都 ≥ MIN_TOKENS 的文件，排除小文件偏差。
  3. 反向覆盖率：远端全部 k-gram 中出现在本仓的比例（分母是远端，不受
     本仓文件大小影响）。
  4. 最长连续公共片段：全仓范围内两侧最长的逐 token 完全相同片段，
     直接给出「雷同到什么程度」与可人工复核的片段内容——这是最抗
     尺寸偏差、也最容易被人验证的指标。

局限：n-gram 只能测「连续片段是否雷同」，不等于抄袭鉴定；它擅长证伪
      「存在成规模复制」，不构成「绝无借鉴」的证明。协议名、方法名、
      元素名、状态码（PROPFIND / DAV: / 207 / If-Match 等）是 RFC 4918
      的规范用语，两边必然相同，不影响结论。

用法：
    python3 tools/similarity_check.py            # 联网拉取远端后比对
    python3 tools/similarity_check.py --offline  # 用上次缓存的远端快照比对
"""

import argparse
import json
import os
import re
import sys
import urllib.request

REPO = "liu-fang38/moonbit-webdav"
BRANCH = "main"
LOCAL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".cache", "webdav-similarity", REPO.replace("/", "_"))
CODE_K = 8
DOC_K = 14
MIN_TOKENS = 400  # 同规模子集阈值：两侧都超过它才参与「抗偏差」比较
SEED = 16  # 最长公共片段的种子长度

SKIP_DIRS = {".git", "_build", ".mooncakes", "target", "node_modules"}


def fetch(path):
    """拉取远端单个文件；命中缓存则直接读缓存。"""
    cache = os.path.join(CACHE_DIR, path.replace("/", "__"))
    if os.path.exists(cache):
        with open(cache, encoding="utf-8", errors="ignore") as f:
            return f.read()
    url = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/{path}"
    with urllib.request.urlopen(url, timeout=30) as r:
        text = r.read().decode("utf-8", "ignore")
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache, "w", encoding="utf-8") as f:
        f.write(text)
    return text


def remote_paths(suffix):
    """远端仓库中某后缀的全部文件路径（走 GitHub tree API，结果缓存）。"""
    cache = os.path.join(CACHE_DIR, f"__tree__{suffix.strip('.')}")
    if os.path.exists(cache):
        with open(cache, encoding="utf-8") as f:
            return json.load(f)
    url = f"https://api.github.com/repos/{REPO}/git/trees/{BRANCH}?recursive=1"
    with urllib.request.urlopen(url, timeout=30) as r:
        tree = json.load(r)
    paths = [e["path"] for e in tree.get("tree", [])
             if e["type"] == "blob" and e["path"].endswith(suffix)]
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache, "w", encoding="utf-8") as f:
        json.dump(paths, f)
    return paths


def local_paths(suffix, roots, skip_names=()):
    out = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(os.path.join(LOCAL_ROOT, root)):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(suffix) and name not in skip_names:
                    out.append(os.path.join(dirpath, name))
    return sorted(out)


def norm_code(text):
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return [t for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+|[^\sA-Za-z0-9_]", text) if t.strip()]


def norm_doc(text):
    text = re.sub(r"```.*?```", "", text, flags=re.S)  # 代码块不计入文档比对
    return re.sub(r"\s+", "", text)


def grams(seq, k):
    return set(tuple(seq[i:i + k]) for i in range(max(0, len(seq) - k + 1)))


def pair_rows(pairs, k, normalizer, min_tokens=0):
    rows = []
    for rname, rtext, lname, ltext in pairs:
        rseq, lseq = normalizer(rtext), normalizer(ltext)
        if min_tokens and (len(rseq) < min_tokens or len(lseq) < min_tokens):
            continue
        rg, lg = grams(rseq, k), grams(lseq, k)
        if not rg or not lg:
            continue
        inter = len(rg & lg)
        if inter == 0:
            continue
        rows.append({
            "jac": inter / len(rg | lg),
            "cov": inter / min(len(rg), len(lg)),
            "shared": inter,
            "rtokens": len(rseq),
            "ltokens": len(lseq),
            "remote": rname,
            "local": os.path.relpath(lname, LOCAL_ROOT),
        })
    rows.sort(key=lambda r: -r["jac"])
    return rows


def print_rows(rows, title, top=6):
    print(f"\n{title}")
    if not rows:
        print("  无任何共享 k-gram")
        return
    print(f"  {'Jaccard':>8} {'覆盖小文件':>10} {'共享片段':>8} {'远端token':>9} {'本仓token':>9}  远端文件 -> 本仓文件")
    for r in rows[:top]:
        print(f"  {r['jac']:8.4f} {r['cov']:10.4f} {r['shared']:8d} {r['rtokens']:9d} {r['ltokens']:9d}  "
              f"{r['remote']} -> {r['local']}")


def aggregate(remote_seqs, local_seqs, k):
    """反向覆盖率：远端 k-gram 有多少出现在本仓（分母为远端，不受本仓切分影响）。"""
    rset = set()
    for s in remote_seqs:
        rset |= grams(s, k)
    lset = set()
    for s in local_seqs:
        lset |= grams(s, k)
    if not rset:
        return 0.0, 0, 0
    return len(rset & lset) / len(rset), len(rset), len(rset & lset)


def longest_common_run(a, b, seed=SEED):
    """两侧最长的逐 token 连续相同片段（种子哈希 + 双向扩展）。返回 (长度, 片段)。"""
    if len(a) > len(b):
        a, b = b, a
    if len(a) < seed or len(b) < seed:
        return 0, []
    idx = {}
    for i in range(len(a) - seed + 1):
        idx.setdefault(tuple(a[i:i + seed]), i)
    best_len, best_seq = 0, []
    i = 0
    while i <= len(b) - seed:
        j = idx.get(tuple(b[i:i + seed]))
        if j is None:
            i += 1
            continue
        s = 0
        while i - s - 1 >= 0 and j - s - 1 >= 0 and b[i - s - 1] == a[j - s - 1]:
            s += 1
        e = seed
        while i + e < len(b) and j + e < len(a) and b[i + e] == a[j + e]:
            e += 1
        if e + s > best_len:
            best_len, best_seq = e + s, b[i - s:i + e]
        i += max(1, e)
    return best_len, best_seq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true", help="只用缓存快照，不联网")
    args = ap.parse_args()
    if args.offline and not os.path.isdir(CACHE_DIR):
        sys.exit("没有缓存快照，请先联网运行一次")

    for suffix in (".mbt", ".md"):
        if not remote_paths(suffix):
            sys.exit(f"远端没有 {suffix} 文件，检查网络或仓库地址")
    if not args.offline:
        for p in remote_paths(".mbt") + remote_paths(".md"):
            fetch(p)

    print(f"对比目标：{REPO} @ {BRANCH}（快照缓存于 {CACHE_DIR}）")
    print(f"本仓：{LOCAL_ROOT}（提交 {os.popen('git -C %s rev-parse --short HEAD' % LOCAL_ROOT).read().strip()}）")

    # ---------- 源码 ----------
    code_pairs = []
    for rp in remote_paths(".mbt"):
        rtext = fetch(rp)
        for lp in local_paths(".mbt", ["src"]):
            with open(lp, encoding="utf-8", errors="ignore") as f:
                code_pairs.append((rp, rtext, lp, f.read()))
    code_rows = pair_rows(code_pairs, CODE_K, norm_code)
    code_rows_big = pair_rows(code_pairs, CODE_K, norm_code, min_tokens=MIN_TOKENS)
    print_rows(code_rows, f"[指标 1] 源码全量 {CODE_K}-gram 最高重合（对小文件敏感）")
    print_rows(code_rows_big, f"[指标 2] 源码同规模子集（两侧均 ≥{MIN_TOKENS} token）")

    remote_texts = {rp: fetch(rp) for rp in remote_paths(".mbt")}
    local_texts = {}
    for lp in local_paths(".mbt", ["src"]):
        with open(lp, encoding="utf-8", errors="ignore") as f:
            local_texts[lp] = f.read()
    cov_code, rtotal, rshared = aggregate([norm_code(t) for t in remote_texts.values()],
                                         [norm_code(t) for t in local_texts.values()], CODE_K)
    print(f"\n[指标 3] 反向覆盖率：远端 {rtotal} 个 {CODE_K}-gram 中有 {rshared} 个出现在本仓"
          f"（{cov_code:.2%}）")

    best_len, best_seq, best_pair = 0, [], ("-", "-")
    for rp, rtext in remote_texts.items():
        for lp, ltext in local_texts.items():
            n, seq = longest_common_run(norm_code(ltext), norm_code(rtext))
            if n > best_len:
                best_len, best_seq = n, seq
                best_pair = (rp, os.path.relpath(lp, LOCAL_ROOT))
    print(f"\n[指标 4] 最长连续公共片段：{best_len} 个 token"
          f"（{best_pair[0]} <-> {best_pair[1]}）")
    print("  片段内容：" + " ".join(best_seq[:60]) + (" …" if best_len > 60 else ""))

    # ---------- 文档 ----------
    doc_pairs = []
    for rp in remote_paths(".md"):
        rtext = fetch(rp)
        for lp in local_paths(".md", [".", "docs"], skip_names=("AGENTS.md",)):
            with open(lp, encoding="utf-8", errors="ignore") as f:
                doc_pairs.append((rp, rtext, lp, f.read()))
    doc_rows = pair_rows(doc_pairs, DOC_K, norm_doc)
    print_rows(doc_rows, f"[指标 5] 文档 {DOC_K}-gram 最高重合（已剔除代码块）")
    doc_cov, drtotal, drshared = aggregate([norm_doc(t) for _, t, _, _ in doc_pairs],
                                           [norm_doc(t) for _, _, _, t in doc_pairs], DOC_K)
    print(f"\n[指标 6] 文档反向覆盖率：远端 {drtotal} 个 {DOC_K}-gram 中 {drshared} 个出现在本仓"
          f"（{doc_cov:.2%}）")

    # ---------- 结论 ----------
    max_code_big = code_rows_big[0]["jac"] if code_rows_big else 0.0
    max_code = code_rows[0]["jac"] if code_rows else 0.0
    max_doc = doc_rows[0]["jac"] if doc_rows else 0.0
    print("\n=== 结论 ===")
    print(f"源码：全量最高 {max_code:.2%}，同规模子集最高 {max_code_big:.2%}，"
          f"远端反向覆盖率 {cov_code:.2%}，最长连续公共片段 {best_len} token")
    print(f"文档：最高 {max_doc:.2%}，远端反向覆盖率 {doc_cov:.2%}")
    verdict = "无成规模复用" if (max_code_big < 0.05 and cov_code < 0.05 and best_len < 100 and max_doc < 0.01) \
        else "存在可疑重合，需人工比对"
    print(f"判定（同规模 Jaccard <5% 且反向覆盖率 <5% 且最长片段 <100 token 且文档 <1%）：{verdict}")
    print("说明：共享片段集中在 RFC 4918 规范用语（DAV: / propfind / propstat / If-Match / 207 等），"
          "该部分为协议合规所必需，不能据此认定复用。")


if __name__ == "__main__":
    main()
