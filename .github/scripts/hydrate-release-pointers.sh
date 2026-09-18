#!/usr/bin/env bash
# Replace Git LFS pointers with real content fetched from the GitHub release the
# mod came from, rather than from the LFS server.
#
# The sync workflow commits pointers without uploading the objects while
# LFS_UPLOADS is off, so a plain checkout leaves those jars as pointer text and
# the `git lfs smudge` that packscripts falls back to has nothing to fetch. Any
# mod whose annotated source is a release asset can be downloaded from there
# instead and verified against the sha256 the pointer already carries. Pointers
# without a release link are left alone for git-lfs to resolve.
#
# Usage: hydrate-release-pointers.sh [mod tag, e.g. SIDE.SERVER]
set -euo pipefail

tag="${1:-}"
header='version https://git-lfs.github.com/spec/v1'
hydrated=0

while IFS=$'\t' read -r file_path source_url sha; do
    [ -f "$file_path" ] || continue
    # Pointers are a few hundred bytes; anything bigger is already real content.
    [ "$(stat -c%s "$file_path")" -lt 512 ] || continue
    case "$(head -c 64 "$file_path")" in
        "$header"*) ;;
        *) continue ;;
    esac

    oid="$(sed -n 's/^oid sha256://p' "$file_path")"
    if [ "$oid" != "$sha" ]; then
        echo "W: $file_path points at $oid but annotated_mods.json has $sha, leaving it to git-lfs."
        continue
    fi

    echo "Hydrating $file_path from $source_url"
    curl -fsSL --retry 3 -o "$file_path.tmp" "$source_url"
    echo "$sha  $file_path.tmp" | sha256sum -c - > /dev/null
    mv "$file_path.tmp" "$file_path"
    hydrated=$((hydrated + 1))
done < <(jq -r --arg tag "$tag" '
    to_entries[] | .value
    | select((.source // "") | test("^https://github\\.com/[^/]+/[^/]+/releases/download/"))
    | select($tag == "" or ((.tags // []) | index($tag)))
    | [.file_path, .source, .update_state.sha256_sum // ""] | @tsv
' annotated_mods.json)

echo "Hydrated $hydrated file(s) from releases."
