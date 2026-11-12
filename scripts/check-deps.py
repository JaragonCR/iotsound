#!/usr/bin/env python3
"""List every external dependency in dependencies.json with its pinned version
and the newest version upstream.

  python3 scripts/check-deps.py            print the table
  python3 scripts/check-deps.py --write    also regenerate docs/DEPENDENCIES.md
  python3 scripts/check-deps.py --offline  skip the upstream lookups

Standard library only. Set GITHUB_TOKEN to avoid GitHub's anonymous rate limit.
"""
import json, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "iotsound-check-deps"})
    tok = os.environ.get("GITHUB_TOKEN")
    if tok and "api.github.com" in url:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def vkey(v):
    return [int(x) for x in re.findall(r"\d+", v)]


def current(dep):
    """Pinned version(s) found in the 'where' files. More than one means drift."""
    if not dep.get("pin"):
        return []
    found = set()
    for rel in dep["where"]:
        try:
            text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        except OSError:
            continue
        found.update(re.findall(dep["pin"], text))
    return sorted(found, key=vkey)


def latest(up):
    t = up["type"]
    if t == "dockerhub":
        tags, url = [], f"https://hub.docker.com/v2/repositories/{up['repo']}/tags?page_size=100&ordering=last_updated"
        for _ in range(4):
            page = get(url)
            tags += [x["name"] for x in page["results"]]
            url = page.get("next")
            if not url:
                break
        hits = [m.group(1) for m in (re.match(up["tag"], x) for x in tags) if m]
        return max(hits, key=vkey) if hits else "?"
    if t == "github-release":
        return get(f"https://api.github.com/repos/{up['repo']}/releases/latest")["tag_name"].lstrip("v")
    if t == "github-tag":
        names = [x["name"].lstrip("v") for x in get(f"https://api.github.com/repos/{up['repo']}/tags?per_page=30")]
        names = [n for n in names if re.fullmatch(r"\d+(\.\d+)+", n)]
        return max(names, key=vkey) if names else "?"
    if t == "npm":
        return get(f"https://registry.npmjs.org/{up['package']}/latest")["version"]
    if t == "gomod":
        return get(f"https://proxy.golang.org/{up['module']}/@latest")["Version"].lstrip("v")
    return "check by hand"


def main():
    offline, write = "--offline" in sys.argv, "--write" in sys.argv
    deps = json.load(open(os.path.join(ROOT, "dependencies.json")))["dependencies"]
    rows, behind = [], 0
    for d in deps:
        cur = current(d)
        cur_s = " / ".join(cur) if cur else "floating"
        if offline:
            new, status = "", ""
        else:
            try:
                new = latest(d["upstream"])
            except Exception as e:  # network or rate limit: report, keep going
                new = f"lookup failed ({type(e).__name__})"
            if len(cur) > 1:
                status = "DRIFT"
            elif cur and re.fullmatch(r"[\d.]+", new) and re.fullmatch(r"[\d.]+", cur[0]):
                status = "behind" if vkey(new)[: len(vkey(cur[0]))] > vkey(cur[0]) else "current"
            else:
                status = "check"
            behind += status in ("behind", "DRIFT")
        rows.append((d, cur_s, new, status))

    print(f"{'dependency':26} {'pinned':14} {'upstream':26} status")
    for d, cur_s, new, status in rows:
        print(f"{d['name']:26} {cur_s:14} {new:26} {status}")
    if not offline:
        print(f"\n{behind} behind or drifting. 'check' rows are floating or need a manual look.")

    if write:
        out = [
            "# Dependencies",
            "",
            "Generated from `dependencies.json` by `python3 scripts/check-deps.py --write`. Do not edit by hand.",
            "",
            "Every external piece of software IoTSound builds on, the version we pin, and every file that pins it.",
            "Run `python3 scripts/check-deps.py` to compare the pins with upstream; every PR does this (see `AGENTS.md`).",
            "",
            "| Dependency | Kind | Pinned | Where used | Notes |",
            "| --- | --- | --- | --- | --- |",
        ]
        for d, cur_s, _, _ in rows:
            where = "<br>".join(f"`{w}`" if "/" in w or "." in w else w for w in d["where"])
            out.append(f"| {d['name']} | {d['kind']} | {cur_s} | {where} | {d['notes']} |")
        out += [
            "",
            "OS packages installed with `apk` or `apt` are not pinned: they follow the base image release in the first rows.",
            "Transitive npm packages are locked in `core/sound-supervisor/package-lock.json`.",
            "",
        ]
        open(os.path.join(ROOT, "docs", "DEPENDENCIES.md"), "w", encoding="utf-8").write("\n".join(out))
        print("wrote docs/DEPENDENCIES.md")


if __name__ == "__main__":
    main()
