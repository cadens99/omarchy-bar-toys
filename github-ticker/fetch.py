#!/usr/bin/env python3
"""Fetch recent GitHub activity for the bar ticker and print it as JSON.

Uses the already-authenticated `gh` CLI, so no token is stored here.
Sources:
  * your own activity (/users/<you>/events, includes private repos)
  * activity by anyone else on your most recently pushed repos
Output: {"ok": true, "items": [{"tag","text","url","age"}...]} or {"ok": false, "error": "..."}
"""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

MAX_ITEMS = 30
REPO_COUNT = 8          # how many of your most recently pushed repos to watch for others' activity
MAX_TEXT = 140
CACHE_DIR = os.path.expanduser("~/.cache/github-ticker")
COMMIT_CACHE = os.path.join(CACHE_DIR, "commits.json")


def find_gh():
    for cand in (
        shutil.which("gh"),
        os.path.expanduser("~/.local/share/mise/shims/gh"),
        "/usr/bin/gh",
    ):
        if cand and os.path.exists(cand):
            return cand
    return None


GH = find_gh()


def gh_api(path):
    res = subprocess.run(
        [GH, "api", "-H", "Accept: application/vnd.github+json", path],
        capture_output=True, text=True, timeout=20,
    )
    if res.returncode != 0:
        raise RuntimeError((res.stderr or "gh api failed").strip().splitlines()[-1][:200])
    return json.loads(res.stdout or "null")


def clip(s, n=MAX_TEXT):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def age(iso):
    try:
        t = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return ""
    secs = max(0, int((datetime.now(timezone.utc) - t).total_seconds()))
    if secs < 60:
        return "now"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def load_commit_cache():
    try:
        with open(COMMIT_CACHE) as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_commit_cache(cache):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        # keep it small
        items = list(cache.items())[-300:]
        tmp = COMMIT_CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(dict(items), f)
        os.replace(tmp, COMMIT_CACHE)
    except Exception:
        pass


def commit_message(repo, sha, cache, budget):
    """GitHub no longer includes commit messages in push events; look up the head commit (cached)."""
    key = f"{repo}@{sha}"
    if key in cache:
        return cache[key]
    if budget[0] <= 0:
        return ""
    budget[0] -= 1
    try:
        data = gh_api(f"/repos/{repo}/commits/{sha}")
        msg = (data.get("commit", {}).get("message") or "").splitlines()[0]
    except Exception:
        msg = ""
    cache[key] = msg
    return msg


def pr_title(repo, num, cache, budget):
    """Event payloads no longer carry PR titles; look them up once and cache."""
    key = f"{repo}#pr{num}"
    if key in cache:
        return cache[key]
    if budget[0] <= 0 or not num:
        return ""
    budget[0] -= 1
    try:
        title = gh_api(f"/repos/{repo}/pulls/{num}").get("title") or ""
    except Exception:
        title = ""
    cache[key] = title
    return title


def describe(ev, me, cache, budget):
    t = ev.get("type")
    p = ev.get("payload") or {}
    repo = ev.get("repo", {}).get("name", "")
    short = repo.split("/", 1)[-1] if repo.startswith(me + "/") else repo
    actor = ev.get("actor", {}).get("login", "")
    who = "" if actor == me else f"{actor} "
    base = f"https://github.com/{repo}"

    if t == "PushEvent":
        branch = (p.get("ref") or "").replace("refs/heads/", "")
        sha = p.get("head") or ""
        msg = commit_message(repo, sha, cache, budget) if sha else ""
        size = p.get("size") or len(p.get("commits") or [])
        what = f"{size} commit{'s' if size != 1 else ''}" if size else "pushed"
        text = f"{who}{what} → {short}/{branch}" if size else f"{who}pushed → {short}/{branch}"
        if msg:
            text += f" — “{msg}”"
        return "PUSH", text, f"{base}/commit/{sha}" if sha else base
    if t == "PullRequestEvent":
        pr = p.get("pull_request") or {}
        action = p.get("action", "")
        if action == "closed" and pr.get("merged"):
            action = "merged"
        num = pr.get("number") or p.get("number")
        title = pr.get("title") or pr_title(repo, num, cache, budget)
        return "PR", f"{who}{action} #{num} in {short}" + (f": {title}" if title else ""), pr.get("html_url") or f"{base}/pull/{num}"
    if t == "PullRequestReviewEvent":
        pr = p.get("pull_request") or {}
        state = (p.get("review") or {}).get("state", "reviewed").lower().replace("_", " ")
        return "REVIEW", f"{who}{state} #{pr.get('number')} in {short}", pr.get("html_url") or base
    if t == "IssuesEvent":
        iss = p.get("issue") or {}
        return "ISSUE", f"{who}{p.get('action','')} #{iss.get('number')} in {short}: {iss.get('title','')}", iss.get("html_url") or base
    if t in ("IssueCommentEvent", "PullRequestReviewCommentEvent", "CommitCommentEvent"):
        iss = p.get("issue") or p.get("pull_request") or {}
        c = p.get("comment") or {}
        num = iss.get("number")
        where = f"#{num} in {short}" if num else short
        return "COMMENT", f"{who}commented on {where}: {(c.get('body') or '').splitlines()[0] if c.get('body') else ''}", c.get("html_url") or base
    if t == "WatchEvent":
        return "STAR", f"{actor} starred {short}", base
    if t == "ForkEvent":
        return "FORK", f"{actor} forked {short}", (p.get("forkee") or {}).get("html_url") or base
    if t == "CreateEvent":
        kind = p.get("ref_type", "")
        if kind == "repository":
            return "NEW", f"{who}created repo {short}", base
        return "NEW", f"{who}created {kind} {p.get('ref','')} in {short}", base
    if t == "DeleteEvent":
        return "DEL", f"{who}deleted {p.get('ref_type','')} {p.get('ref','')} in {short}", base
    if t == "ReleaseEvent":
        rel = p.get("release") or {}
        return "RELEASE", f"{short} {rel.get('tag_name','')} {rel.get('name') or ''}".strip(), rel.get("html_url") or base
    if t == "PublicEvent":
        return "PUBLIC", f"{short} is now public", base
    if t == "MemberEvent":
        m = (p.get("member") or {}).get("login", "")
        return "MEMBER", f"{m} added to {short}", base
    return None


CI_DAYS = 3                 # ignore CI results older than this
CI_PIN_HOURS = 48           # failures newer than this go to the front of the ticker
CI_FAIL = {"failure", "timed_out", "startup_failure"}
CI_SKIP = {"skipped", "cancelled", "neutral", "action_required", "stale"}
CI_SEEN = os.path.join(CACHE_DIR, "ci-seen.json")


def parse_ts(iso):
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0


def ci_items(repos, me):
    """Latest completed run per (workflow, branch): FAIL if it failed, FIXED if it
    passed right after a failure. Passing runs are not shown."""
    out = []
    cutoff = time.time() - CI_DAYS * 86400
    for repo in repos:
        try:
            runs = (gh_api(f"/repos/{repo}/actions/runs?per_page=40") or {}).get("workflow_runs") or []
        except Exception:
            continue
        groups = {}
        for r in runs:
            if r.get("status") != "completed" or r.get("conclusion") in CI_SKIP:
                continue
            groups.setdefault((r.get("workflow_id"), r.get("head_branch")), []).append(r)
        short = repo.split("/", 1)[-1] if repo.startswith(me + "/") else repo
        for runs_for in groups.values():
            runs_for.sort(key=lambda r: r.get("updated_at", ""), reverse=True)
            top = runs_for[0]
            ts = parse_ts(top.get("updated_at", ""))
            if ts < cutoff:
                continue
            name = top.get("name") or "CI"
            branch = top.get("head_branch") or "?"
            title = top.get("display_title") or ""
            if top.get("conclusion") in CI_FAIL:
                text = f"{name} failed on {short}/{branch}" + (f": {title}" if title else "")
                out.append({"tag": "FAIL", "text": text, "url": top.get("html_url") or "",
                            "ts": ts, "run": str(top.get("id")), "title": f"{name} failed: {short}/{branch}",
                            "body": title})
            elif top.get("conclusion") == "success" and len(runs_for) > 1 \
                    and runs_for[1].get("conclusion") in CI_FAIL:
                out.append({"tag": "FIXED", "text": f"{name} passing again on {short}/{branch}",
                            "url": top.get("html_url") or "", "ts": ts})
    return out


def notify_new_failures(fails):
    """Desktop notification for failures not seen before. The first run ever only
    records what is already failing, so you don't get a burst of old alerts."""
    try:
        with open(CI_SEEN) as f:
            seen = json.load(f)
        first_run = False
    except Exception:
        seen, first_run = {}, True
    for it in fails:
        rid = it.get("run")
        if not rid or rid in seen:
            continue
        seen[rid] = int(time.time())
        if not first_run:
            subprocess.run(["notify-send", "-u", "critical", "-a", "GitHub CI",
                            clip(it.get("title", "CI failed"), 120), clip(it.get("body", ""), 200)],
                           timeout=5, check=False)
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        keep = dict(sorted(seen.items(), key=lambda kv: kv[1])[-500:])
        with open(CI_SEEN + ".tmp", "w") as f:
            json.dump(keep, f)
        os.replace(CI_SEEN + ".tmp", CI_SEEN)
    except Exception:
        pass


def main():
    if not GH:
        print(json.dumps({"ok": False, "error": "gh CLI not found"}))
        return
    try:
        me = gh_api("/user")["login"]
        events = {}
        for ev in gh_api(f"/users/{me}/events?per_page=50") or []:
            events[ev["id"]] = ev
        repos = gh_api(f"/user/repos?affiliation=owner&sort=pushed&per_page={REPO_COUNT}") or []
        for r in repos:
            try:
                for ev in gh_api(f"/repos/{r['full_name']}/events?per_page=20") or []:
                    events.setdefault(ev["id"], ev)
            except Exception:
                continue
    except Exception as e:
        print(json.dumps({"ok": False, "error": clip(str(e), 200)}))
        return

    ordered = sorted(events.values(), key=lambda e: e.get("created_at", ""), reverse=True)
    cache = load_commit_cache()
    budget = [25]  # max new commit/PR-title lookups per run (results are cached)
    feed = []
    for ev in ordered:
        d = describe(ev, me, cache, budget)
        if not d:
            continue
        tag, text, url = d
        feed.append({"tag": tag, "text": text, "url": url, "ts": parse_ts(ev.get("created_at", ""))})
        if len(feed) >= MAX_ITEMS:
            break
    save_commit_cache(cache)

    # CI: your owned repos plus any repo you've been active in (e.g. other orgs).
    watch = [r["full_name"] for r in repos]
    for ev in ordered:
        name = ev.get("repo", {}).get("name")
        if name and name not in watch:
            watch.append(name)
    ci = ci_items(watch[:12], me)
    fails = [c for c in ci if c["tag"] == "FAIL"]
    notify_new_failures(fails)

    # Fresh failures lead the ticker; everything else is newest first.
    pin_after = time.time() - CI_PIN_HOURS * 3600
    pinned = sorted([c for c in fails if c["ts"] >= pin_after], key=lambda c: c["ts"], reverse=True)
    rest = sorted([x for x in feed + ci if x not in pinned], key=lambda x: x["ts"], reverse=True)

    items = []
    for x in (pinned + rest)[:MAX_ITEMS]:
        iso = datetime.fromtimestamp(x["ts"], timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if x["ts"] else ""
        items.append({"tag": x["tag"], "text": clip(x["text"]), "url": str(x["url"])[:400], "age": age(iso)})
    print(json.dumps({"ok": True, "items": items, "fetched": int(time.time())}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never leave the widget with nothing to parse
        print(json.dumps({"ok": False, "error": clip(str(e), 200)}))
        sys.exit(0)
