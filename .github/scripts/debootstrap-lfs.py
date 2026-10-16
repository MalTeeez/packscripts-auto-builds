#!/usr/bin/env python3
"""Repoint the LFS urls in bootstrap.json at the releases the mods came from.

bootstrap.json is the fresh-install baseline and has never been regenerated, so
it still serves ~366 MiB per install out of Git LFS. Its file set and hashes are
correct — only the urls are wrong — so rather than rebuilding it (packscripts
`package bootstrap` cannot run: Bun drops ~1 in 60 of the ~25k subprocesses it
spawns), each LFS url is rewritten to the release asset holding that exact
content, with the old url demoted to mirror_url, exactly as packscripts does for
mods it can resolve.

Every rewrite is verified by downloading the candidate and comparing its sha256
to the hash bootstrap.json already records; anything that does not match is left
alone and reported. Entries with no release (Thaumcraft, the resourcepack, the
galacticraft .oggs, scala-compiler) can only be served raw from the repo, which
needs the commit that drops them out of LFS, so they are reported as pending.

Usage: debootstrap-lfs.py [--write] [--raw-commit <sha>]
  --write              apply the changes (default is a dry run)
  --raw-commit <sha>   also repoint release-less files at raw.githubusercontent
                       at this commit, where they must be committed raw
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request

REPO_RAW = "https://raw.githubusercontent.com/malteeez/packscripts-auto-builds"
ROOT = pathlib.Path(__file__).resolve().parents[2]


def is_lfs_url(url):
    return "/raw/" in url and "raw.githubusercontent" not in url


def mod_index(annotated):
    """Map a mod's release repo + filename shape, keyed by its stripped basename."""
    index = {}
    for mod in annotated.values():
        source = mod.get("source") or ""
        m = re.match(
            r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$", source
        )
        if not m:
            continue
        owner, repo, tag, filename = m.groups()
        if tag not in filename:
            continue
        head, _, tail = filename.partition(tag)
        index[strip_version(filename)] = (owner, repo, head, tail)
    return index


def strip_version(basename):
    """'gregtech-5.09.52.461.jar' -> 'gregtech'; must match across versions."""
    return re.split(r"[-_]?\d", basename, 1)[0].lower()


def candidate_url(path, index):
    basename = path.rsplit("/", 1)[-1]
    entry = index.get(strip_version(basename))
    if entry is None:
        return None
    owner, repo, head, tail = entry
    if not basename.startswith(head) or not basename.endswith(tail):
        return None
    tag = basename[len(head) : len(basename) - len(tail)] if tail else basename[len(head) :]
    if not tag:
        return None
    return f"https://github.com/{owner}/{repo}/releases/download/{tag}/{basename}"


def repo_path_of(pack_path, variant):
    """Invert the variant's include_as mapping: pack path -> path in this repo.

    The client packs .minecraft/ as-is, but the server renames into it ('mods/x'
    is '.minecraft/mods/x', 'libraries/x' is 'packaging/server/libraries/x'), so
    a raw url built from the pack path alone would 404.
    """
    config = json.loads((ROOT / "packscripts.json").read_text())
    mappings = []
    pack_variant = config["PACKAGING"]["PACK_VARIANTS"][variant]
    for key in ("TRACK_INCLUDE_PATHS", "FORCE_INCLUDE_PATHS"):
        for item in pack_variant[key]:
            source = item["path"].removeprefix("./").rstrip("/")
            mappings.append((item.get("include_as", source).rstrip("/"), source))
    # Longest include_as first so 'mods' never shadows a more specific prefix.
    for include_as, source in sorted(mappings, key=lambda m: -len(m[0])):
        if include_as and (pack_path == include_as or pack_path.startswith(include_as + "/")):
            return source + pack_path[len(include_as) :]
        if not include_as:  # whole directory mapped onto the pack root
            return f"{source}/{pack_path}"
    return pack_path


def sha256_of(url):
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            for chunk in iter(lambda: response.read(1 << 20), b""):
                digest.update(chunk)
    except Exception as err:  # noqa: BLE001 - any failure just means "don't rewrite"
        return None, str(err)
    return digest.hexdigest(), None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--raw-commit")
    args = parser.parse_args()

    annotated = json.loads((ROOT / "annotated_mods.json").read_text())
    index = mod_index(annotated)
    totals = {"rewritten": 0, "pending": 0, "mismatch": 0, "bytes": 0}

    for variant in ("client", "server"):
        bootstrap_path = ROOT / "packaging" / variant / "unsup" / "bootstrap.json"
        bootstrap = json.loads(bootstrap_path.read_text())
        changed = False
        print(f"\n=== {variant} ({bootstrap['version']['name']}, code {bootstrap['version']['code']})")

        for entry in bootstrap["files"]:
            if not is_lfs_url(entry["url"]):
                continue
            # The path inside the pack differs per variant ('mods/x' vs '.minecraft/mods/x').
            url = candidate_url(entry["path"], index)
            label = f"{entry['size'] / 1048576:6.1f} MiB  {entry['path']}"

            if url is None:
                if args.raw_commit:
                    in_repo = repo_path_of(entry["path"], variant)
                    url = f"{REPO_RAW}/{args.raw_commit}/{urllib.parse.quote(in_repo)}"
                else:
                    print(f"  PENDING  {label}  (no release; needs the raw commit)")
                    totals["pending"] += 1
                    continue

            got, err = sha256_of(url)
            if got is None:
                print(f"  UNREACHABLE {label}  {err}")
                totals["mismatch"] += 1
                continue
            if got != entry["hash"]:
                print(f"  MISMATCH {label}  (got {got[:12]}, want {entry['hash'][:12]})")
                totals["mismatch"] += 1
                continue

            entry["mirror_url"] = entry["url"]
            entry["url"] = url
            changed = True
            totals["rewritten"] += 1
            totals["bytes"] += entry["size"]
            print(f"  OK       {label}")

        if changed and args.write:
            bootstrap_path.write_text(json.dumps(bootstrap, indent=4) + "\n")
            print(f"  -> wrote {bootstrap_path.relative_to(ROOT)}")

    print(
        f"\nrewritten: {totals['rewritten']} ({totals['bytes'] / 1048576:.0f} MiB/install off LFS)"
        f"  pending: {totals['pending']}  problems: {totals['mismatch']}"
    )
    return 1 if totals["mismatch"] else 0


if __name__ == "__main__":
    sys.exit(main())
