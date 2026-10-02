#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""百度千帆联网搜索 —— 命令行工具（纯标准库，无第三方依赖）。

源自用户的 `千帆搜索-独立实现.py`，改造要点：
  · 去掉 nonebot / httpx 依赖，改用 urllib.request（任何 Python 3.8+ 都能跑）；
  · 从「异步库里被 import 的函数」变成「可独立执行的 CLI」，方便 Agent 直接调用；
  · 配额计数**落盘**（原版是进程内变量，Agent 每次都是新进程，等于没计数）；
  · 错误不再静默吞掉：失败打印到 stderr 并返回非 0 退出码。

用法：
    python qianfan_search.py "关键词"                 # 默认 top-6，摘要总长 1200
    python qianfan_search.py "关键词" --top-k 10
    python qianfan_search.py "关键词" --recency month --max-chars 3000
    python qianfan_search.py "关键词" --json          # 结构化输出，便于程序解析
    python qianfan_search.py --quota                 # 只查今日剩余额度，不消耗

API Key 查找顺序：--key > 环境变量 QIANFAN_API_KEY > 同目录 config.json 的 api_key
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_URL = "https://qianfan.baidubce.com/v2/ai_search/web_search"

HERE = Path(__file__).resolve().parent
SKILL_ROOT = HERE.parent
CONFIG_PATH = SKILL_ROOT / "config.json"
QUOTA_PATH = SKILL_ROOT / ".quota.json"

# 千帆免费额度 100 次/天；留 5 次余量，与原版一致。
DEFAULT_DAILY_LIMIT = 95
DEFAULT_TOP_K = 6
DEFAULT_MAX_CHARS = 1200
DEFAULT_RECENCY = "year"
VALID_RECENCY = ("day", "week", "month", "year")
TIMEOUT_S = 25


# ─────────────────────────── 配置 / 配额 ───────────────────────────

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {}
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:  # 配置坏了不能拖垮搜索
        print(f"[warn] {CONFIG_PATH} 解析失败，忽略：{exc}", file=sys.stderr)
        return {}


def resolve_key(cli_key: str | None, cfg: dict) -> str:
    key = (cli_key or os.environ.get("QIANFAN_API_KEY") or cfg.get("api_key") or "").strip()
    if not key:
        print(
            "[error] 缺少千帆 API Key。三种给法任选其一：\n"
            "        1) --key <KEY>\n"
            "        2) 环境变量 QIANFAN_API_KEY\n"
            f'        3) 写入 {CONFIG_PATH}：{{"api_key": "<KEY>"}}',
            file=sys.stderr,
        )
        sys.exit(2)
    return key


def today() -> str:
    return time.strftime("%Y-%m-%d")


def read_quota() -> dict:
    """读今日计数；跨天自动归零。落盘是为了跨进程有效。"""
    limit = int(load_config().get("daily_limit") or DEFAULT_DAILY_LIMIT)
    state = {"date": today(), "n": 0}
    if QUOTA_PATH.exists():
        try:
            raw = json.loads(QUOTA_PATH.read_text(encoding="utf-8"))
            if raw.get("date") == today():
                state["n"] = int(raw.get("n") or 0)
        except Exception:
            pass
    return {"date": state["date"], "n": state["n"], "limit": limit,
            "left": max(0, limit - state["n"])}


def bump_quota() -> None:
    state = read_quota()
    payload = {"date": state["date"], "n": state["n"] + 1}
    try:
        QUOTA_PATH.write_text(json.dumps(payload), encoding="utf-8")
    except Exception:
        pass  # 计数失败不影响搜索本身


# ─────────────────────────── 搜索 ───────────────────────────

def call_api(key: str, query: str, top_k: int, recency: str) -> dict:
    payload = {
        "messages": [{"role": "user", "content": query[:200]}],
        "search_source": "baidu_search_v2",
        "resource_type_filter": [{"type": "web", "top_k": top_k}],
        "search_recency_filter": recency,
    }
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"HTTP {exc.code} {exc.reason}：{detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"网络不可达：{exc.reason}") from None
    except TimeoutError:
        raise RuntimeError(f"请求超时（>{TIMEOUT_S}s）") from None

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        raise RuntimeError(f"响应不是合法 JSON：{body[:300]}") from None

    # 千帆出错时返回 {"code":..., "message":...}（HTTP 可能仍是 200）
    if isinstance(data, dict) and data.get("code") and not (
        data.get("references") or data.get("search_results")
    ):
        raise RuntimeError(f"API 报错 code={data.get('code')}：{data.get('message')}")
    return data


def normalize(data: dict, max_chars: int) -> tuple[str, list[dict]]:
    """把 references 归一化成 (正文拼装文本, 结构化结果列表)。"""
    refs = data.get("references") or data.get("search_results") or []
    chunks: list[str] = []
    items: list[dict] = []
    used = 0
    for i, it in enumerate(refs, 1):
        if not isinstance(it, dict):
            continue
        title = str(it.get("title") or it.get("web_anchor") or "").strip()
        body = str(it.get("content") or it.get("summary") or it.get("abstract") or "").strip()
        url = str(it.get("url") or "").strip()
        if not body:
            continue
        piece = f"[{i}] {title}\n{body}" if title else f"[{i}] {body}"
        if used + len(piece) > max_chars:
            piece = piece[: max(0, max_chars - used)]
        chunks.append(piece)
        used += len(piece)
        items.append({"index": i, "title": title, "url": url, "content": body})
        if used >= max_chars:
            break
    return "\n\n".join(chunks), items


# ─────────────────────────── CLI ───────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="qianfan_search.py",
        description="百度千帆联网搜索（web_search），输出带来源 URL 的摘要。",
    )
    p.add_argument("query", nargs="?", help="搜索关键词（中文/英文均可）")
    p.add_argument("--top-k", type=int, default=None, help=f"返回条数，默认 {DEFAULT_TOP_K}")
    p.add_argument("--max-chars", type=int, default=None,
                   help=f"正文总长度上限，默认 {DEFAULT_MAX_CHARS}")
    p.add_argument("--recency", default=None, choices=VALID_RECENCY,
                   help=f"时效过滤，默认 {DEFAULT_RECENCY}")
    p.add_argument("--key", default=None, help="临时指定 API Key（一般不必要）")
    p.add_argument("--json", action="store_true", help="输出结构化 JSON")
    p.add_argument("--quota", action="store_true", help="只查今日剩余额度后退出")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cfg = load_config()

    if args.quota:
        q = read_quota()
        print(f"今日已用 {q['n']}/{q['limit']}，剩余 {q['left']} 次（{q['date']}）")
        return 0

    query = (args.query or "").strip()
    if not query:
        print("[error] 缺少搜索关键词。用法：qianfan_search.py \"关键词\"", file=sys.stderr)
        return 2

    quota = read_quota()
    if quota["left"] <= 0:
        print(
            f"[error] 今日额度已用完（{quota['n']}/{quota['limit']}），请明天再试。"
            f"如确认仍有额度，可删掉 {QUOTA_PATH} 重置本地计数。",
            file=sys.stderr,
        )
        return 3

    key = resolve_key(args.key, cfg)
    top_k = args.top_k or int(cfg.get("top_k") or DEFAULT_TOP_K)
    max_chars = args.max_chars or int(cfg.get("max_chars") or DEFAULT_MAX_CHARS)
    recency = args.recency or cfg.get("recency") or DEFAULT_RECENCY

    try:
        data = call_api(key, query, top_k, recency)
    except RuntimeError as exc:
        print(f"[error] 搜索失败：{exc}", file=sys.stderr)
        return 1
    bump_quota()

    text, items = normalize(data, max_chars)
    if args.json:
        print(json.dumps(
            {
                "query": query,
                "count": len(items),
                "results": items,
                "sources": [i["url"] for i in items if i["url"]],
                "quota_left": read_quota()["left"],
            },
            ensure_ascii=False,
            indent=2,
        ))
        return 0

    if not items:
        print(f"[warn] 未检索到结果（query={query}，recency={recency}）。", file=sys.stderr)
        return 4

    print(text)
    print("\n--- 来源 ---")
    for it in items:
        if it["url"]:
            print(f"[{it['index']}] {it['url']}")
    print(f"\n（今日剩余额度 {read_quota()['left']} 次）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
