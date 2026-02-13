#!/usr/bin/env python3
import argparse
import bisect
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


API_URL = os.environ.get("WAYBAR_NEWS_API", "").strip()
API_URLS = [u.strip() for u in (API_URL or "http://127.0.0.1:5000/api/tape?limit=80&includeOverview=true,http://127.0.0.1:5000/api/posts?limit=80&sortBy=recent").split(",") if u.strip()]
REQUEST_TIMEOUT = float(os.environ.get("WAYBAR_NEWS_TIMEOUT", "2.5"))
CACHE_TTL_SECONDS = int(os.environ.get("WAYBAR_NEWS_CACHE_TTL", "120"))
FRAME_DELAY_SECONDS = float(os.environ.get("WAYBAR_NEWS_SCROLL_DELAY", "0.18"))
VISIBLE_WIDTH = int(os.environ.get("WAYBAR_NEWS_VISIBLE_WIDTH", "120"))
SCROLL_STEP = float(os.environ.get("WAYBAR_NEWS_SCROLL_STEP", "1"))
TICK_STEP = float(os.environ.get("WAYBAR_NEWS_TICK_STEP", "4"))
STATE_PATH = Path.home() / ".cache" / "waybar-news-ribbon.json"

CYBER_COMMANDS = {"CYBERCOM"}
FINANCE_COMMANDS = {"FINCOM"}
MILITARY_COMMANDS = {
    "AFRICOM",
    "CENTCOM",
    "EUCOM",
    "INDOPACOM",
    "NORTHCOM",
    "SOUTHCOM",
    "SPACECOM",
    "SOCOM",
    "STRATCOM",
    "TRANSCOM",
}

CYBER_KEYWORDS = {
    "cyber",
    "ransomware",
    "malware",
    "breach",
    "exploit",
    "zero-day",
    "ddos",
    "phishing",
    "botnet",
    "vulnerability",
    "infosec",
    "hack",
    "hacker",
}
FINANCE_KEYWORDS = {
    "finance",
    "financial",
    "bank",
    "banking",
    "branch",
    "branches",
    "central bank",
    "federal reserve",
    "fed",
    "ecb",
    "interest rate",
    "inflation",
    "recession",
    "debt",
    "bond",
    "credit",
    "liquidity",
    "lender",
    "loan",
    "forex",
    "market",
    "treasury",
    "sanction",
}
MILITARY_KEYWORDS = {
    "military",
    "defense",
    "army",
    "navy",
    "air force",
    "marine",
    "troop",
    "battalion",
    "brigade",
    "drone",
    "missile",
    "strike",
    "war",
    "battle",
    "conflict",
    "nato",
    "artillery",
    "submarine",
    "carrier",
    "frontline",
    "ceasefire",
}


def load_state() -> dict[str, Any]:
    try:
        if STATE_PATH.exists():
            return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {"fetched_at": 0, "headline_index": 0, "scroll_offset": 0, "items": []}


def save_state(state: dict[str, Any]) -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(json.dumps(state), encoding="utf-8")
    except Exception:
        pass


def detect_topics(post: dict[str, Any], title: str, source: str) -> list[str]:
    topics: list[str] = []
    text_blob = " ".join(
        [
            title,
            source,
            str(post.get("summary", "")),
            str(post.get("keywords", "")),
            str(post.get("content", ""))[:600],
        ]
    ).lower()

    commands: set[str] = set()
    raw_commands = post.get("commands", [])
    if isinstance(raw_commands, list):
        for c in raw_commands:
            if isinstance(c, dict):
                cmd = str(c.get("command", "")).strip().upper()
                if cmd:
                    commands.add(cmd)
            elif isinstance(c, str):
                cmd = c.strip().upper()
                if cmd:
                    commands.add(cmd)
    elif isinstance(raw_commands, str):
        cmd = raw_commands.strip().upper()
        if cmd:
            commands.add(cmd)

    category = str(post.get("category", "")).strip().upper()
    if category:
        commands.add(category)
    command = str(post.get("command", "")).strip().upper()
    if command:
        commands.add(command)

    if commands & CYBER_COMMANDS or any(k in text_blob for k in CYBER_KEYWORDS):
        topics.append("CYBER")
    if commands & FINANCE_COMMANDS or any(k in text_blob for k in FINANCE_KEYWORDS):
        topics.append("FINANCE")
    if commands & MILITARY_COMMANDS or any(k in text_blob for k in MILITARY_KEYWORDS):
        topics.append("MILITARY")

    return topics


def normalize_items(raw_items: list[Any]) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        title = " ".join(str(raw.get("title", "")).split()).strip()
        source = " ".join(str(raw.get("source", raw.get("sourceName", "Unknown"))).split()).strip()
        tape_text = " ".join(str(raw.get("tapeText", "")).split()).strip()
        updated_at = " ".join(str(raw.get("updatedAt", "")).split()).strip()
        if not title:
            continue
        topic = str(raw.get("topic", "")).strip()
        if not topic:
            inferred = detect_topics(raw, title, source)
            if not inferred:
                continue
            topic = "/".join(inferred)
        items.append(
            {
                "title": title,
                "source": source,
                "topic": topic,
                "tape_text": tape_text,
                "updated_at": updated_at,
            }
        )
    return items


def fetch_posts() -> list[dict[str, str]]:
    payload: dict[str, Any] | list[Any] | None = None
    last_error: Exception | None = None
    for url in API_URLS:
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "waybar-news-ribbon/1.0"},
            )
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
            if raw.lstrip().startswith("<!DOCTYPE") or raw.lstrip().startswith("<html"):
                raise ValueError(f"Non-JSON response from {url}")
            payload = json.loads(raw)
            break
        except Exception as exc:
            last_error = exc
            continue

    if payload is None:
        if last_error:
            raise last_error
        raise RuntimeError("No API endpoints configured")

    posts = payload.get("items", payload.get("posts", payload if isinstance(payload, list) else []))
    if isinstance(posts, dict):
        posts = posts.get("items", [])
    if not isinstance(posts, list):
        posts = []

    items: list[dict[str, str]] = []
    for post in posts:
        if not isinstance(post, dict):
            continue
        title = " ".join(str(post.get("title", "")).split()).strip()
        source = " ".join(str(post.get("sourceName", post.get("source", "Unknown"))).split()).strip()
        tape_text = " ".join(str(post.get("tapeText", "")).split()).strip()
        updated_at = " ".join(str(post.get("updatedAt", "")).split()).strip()
        if not title:
            continue
        topics = detect_topics(post, title, source)
        if not topics:
            continue
        items.append(
            {
                "title": title,
                "source": source,
                "topic": "/".join(topics),
                "tape_text": tape_text,
                "updated_at": updated_at,
            }
        )
    return items


def emit(text: str, tooltip: str, cls: str) -> None:
    try:
        print(
            json.dumps(
                {
                    "text": text,
                    "tooltip": tooltip,
                    "class": cls,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
    except BrokenPipeError:
        sys.exit(0)


def build_tooltip(current_source: str, items: list[dict[str, str]], error_text: str) -> str:
    tooltip_lines = [f"Source: {current_source}", "", "Recent headlines:"]
    for i, item in enumerate(items[: min(5, len(items))], start=1):
        stamp = item.get("updated_at", "")
        if stamp:
            tooltip_lines.append(f"{i}. [{item['topic']}] {item['title']} ({stamp})")
        else:
            tooltip_lines.append(f"{i}. [{item['topic']}] {item['title']}")
    if error_text:
        tooltip_lines.extend(["", f"Refresh warning: {error_text}"])
    return "\n".join(tooltip_lines)


def build_story_track(items: list[dict[str, str]]) -> tuple[str, list[int], list[dict[str, str]]]:
    # Keep only first occurrence of a headline to reduce obvious repeats.
    unique_items: list[dict[str, str]] = []
    seen_titles: set[str] = set()
    for item in items:
        title_key = item["title"].strip().lower()
        if not title_key or title_key in seen_titles:
            continue
        seen_titles.add(title_key)
        unique_items.append(item)

    if not unique_items:
        return "", [], []

    sep = "   ✦   "
    starts: list[int] = []
    parts: list[str] = []
    pos = 0
    for item in unique_items:
        body = item.get("tape_text", "").strip() or item["title"]
        segment = f"󰎕 [{item['topic']}] {body}{sep}"
        starts.append(pos)
        parts.append(segment)
        pos += len(segment)

    return "".join(parts), starts, unique_items


def active_item_index(starts: list[int], offset: float, total_len: int) -> int:
    if not starts or total_len <= 0:
        return 0
    wrapped = offset % total_len
    idx = bisect.bisect_right(starts, wrapped) - 1
    return max(0, min(idx, len(starts) - 1))


def render_story_window(track: str, start: float, width: int) -> str:
    if not track:
        return ""
    safe_width = max(1, width)
    cycle_len = len(track)
    if cycle_len <= 0:
        return ""
    offset = int(start % cycle_len)
    repeated = track * ((safe_width // cycle_len) + 3)
    return repeated[offset : offset + safe_width]


def stream_ticker() -> None:
    state = load_state()
    items: list[dict[str, str]] = normalize_items(state.get("items", []))
    fetched_at = int(state.get("fetched_at", 0))
    headline_index = int(state.get("headline_index", 0))
    scroll_offset = float(state.get("scroll_offset", 0))
    error_text = ""
    last_save_at = 0
    last_emit_text = ""
    last_emit_tooltip = ""
    last_emit_class = ""
    track = ""
    starts: list[int] = []
    unique_items: list[dict[str, str]] = []

    if items:
        track, starts, unique_items = build_story_track(items)

    while True:
        now = int(time.time())
        is_stale = now - fetched_at > CACHE_TTL_SECONDS

        if is_stale or not items:
            try:
                fetched_items = fetch_posts()
                if fetched_items:
                    items = fetched_items
                    fetched_at = now
                    error_text = ""
                    track, starts, unique_items = build_story_track(items)
                    if track:
                        scroll_offset = scroll_offset % len(track)
                    # Save full state when feed refreshes.
                    save_state(
                        {
                            "fetched_at": fetched_at,
                            "headline_index": headline_index,
                            "scroll_offset": scroll_offset,
                            "items": items,
                        }
                    )
                else:
                    error_text = "No posts returned by API"
            except Exception as exc:
                error_text = str(exc)

        if not items:
            emit(
                "󰎕 Waiting for CYBER / FINANCE / MILITARY headlines",
                "No matching headlines right now.\nFeed is still active; new items will appear automatically.",
                "news-stale",
            )
            time.sleep(max(0.8, FRAME_DELAY_SECONDS))
            continue

        if not track or not unique_items:
            emit(
                "󰎕 Waiting for CYBER / FINANCE / MILITARY headlines",
                "No matching headlines right now.\nFeed is still active; new items will appear automatically.",
                "news-stale",
            )
            time.sleep(max(0.8, FRAME_DELAY_SECONDS))
            continue

        idx = active_item_index(starts, scroll_offset, len(track))
        current = unique_items[idx]
        display = render_story_window(track, scroll_offset, VISIBLE_WIDTH)

        if not display:
            display = f"󰎕 [{current['topic']}] {current['title']}"
        tooltip = build_tooltip(current["source"], items, error_text)
        cls = "news-ok" if not error_text else "news-stale"
        if display != last_emit_text or tooltip != last_emit_tooltip or cls != last_emit_class:
            emit(display, tooltip, cls)
            last_emit_text = display
            last_emit_tooltip = tooltip
            last_emit_class = cls

        scroll_offset = (scroll_offset + max(0.1, SCROLL_STEP)) % len(track)
        now = int(time.time())
        if now - last_save_at >= 5:
            headline_index = idx
            # Save lightweight runtime cursor only to avoid stutter.
            state = {
                "fetched_at": fetched_at,
                "headline_index": headline_index,
                "scroll_offset": scroll_offset,
            }
            save_state(state)
            last_save_at = now

        time.sleep(max(0.05, FRAME_DELAY_SECONDS))


def one_shot() -> None:
    state = load_state()
    now = int(time.time())
    items: list[dict[str, str]] = normalize_items(state.get("items", []))
    fetched_at = int(state.get("fetched_at", 0))
    headline_index = int(state.get("headline_index", 0))
    scroll_offset = float(state.get("scroll_offset", 0))
    error_text = ""

    if now - fetched_at > CACHE_TTL_SECONDS or not items:
        try:
            fetched_items = fetch_posts()
            if fetched_items:
                items = fetched_items
                fetched_at = now
                state = {
                    "fetched_at": fetched_at,
                    "headline_index": headline_index,
                    "scroll_offset": scroll_offset,
                    "items": items,
                }
                save_state(state)
            else:
                error_text = "No posts returned by API"
        except Exception as exc:
            error_text = str(exc)

    if not items:
        emit(
            "󰎕 Waiting for CYBER / FINANCE / MILITARY headlines",
            "No matching headlines right now.\nFeed is still active; new items will appear automatically.",
            "news-stale",
        )
        return

    track, starts, unique_items = build_story_track(items)
    if not track or not unique_items:
        emit(
            "󰎕 Waiting for CYBER / FINANCE / MILITARY headlines",
            "No matching headlines right now.\nFeed is still active; new items will appear automatically.",
            "news-stale",
        )
        return

    idx = active_item_index(starts, scroll_offset, len(track))
    current = unique_items[idx]
    text = render_story_window(track, scroll_offset, VISIBLE_WIDTH)
    if not text:
        text = f"󰎕 [{current['topic']}] {current['title']}"
    tooltip = build_tooltip(current["source"], items, error_text)
    emit(text, tooltip, "news-ok" if not error_text else "news-stale")

    scroll_offset = (scroll_offset + max(0.1, TICK_STEP)) % len(track)
    headline_index = idx
    save_state(
        {
            "fetched_at": fetched_at,
            "headline_index": headline_index,
            "scroll_offset": scroll_offset,
            "items": items,
        }
    )


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--stream", action="store_true")
    args = parser.parse_args()

    if args.stream:
        try:
            stream_ticker()
        except KeyboardInterrupt:
            sys.exit(0)
    else:
        one_shot()


if __name__ == "__main__":
    main()
