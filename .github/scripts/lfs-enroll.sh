#!/usr/bin/env bash
# Rebuild .gitattributes, deciding per large file whether it can be a Git LFS
# pointer or has to be committed as plain bytes.
#
# With LFS_UPLOADS=false nothing is tracked at all: every large file is committed
# raw. Two reasons it has to be all-or-nothing rather than "keep the pointers
# whose object is already stored":
#   - GitHub refuses a push referencing an LFS object it does not store (GH008,
#     enforced from the pointer *content*, so leaving the path out of
#     .gitattributes does not help), so new content can never be a pointer.
#   - A pointer that stays behind is still *read* from LFS — by the image build's
#     smudge and by every client install — which bills bandwidth just as uploads
#     bill storage.
# Raw costs repo size but keeps every url working: packscripts hashes blob
# content, so a raw jar still matches annotated_mods.json and its manifest url
# stays the GitHub release, with raw.githubusercontent as a mirror that resolves.
set -euo pipefail

lfs_uploads="${LFS_UPLOADS:-true}"

# `git push` uploads objects from the pre-push hook and nowhere else, so with
# uploads off the hook is replaced by a no-op. Both `git lfs install` and every
# `git lfs track` call (re)install that hook, so neither may run as-is: the
# filters that turn staged files into pointers are set by hand instead, and
# GIT_LFS_TRACK_NO_INSTALL_HOOKS stops `track` from putting the hook back.
neutralize_pre_push() {
    mkdir -p .git/hooks
    printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
}

if [ "$lfs_uploads" = "true" ]; then
    # --force replaces the no-op hook that a run with uploads off leaves behind.
    git lfs install --local --force
else
    neutralize_pre_push
fi

rm -f .gitattributes

raw=()
raw_bytes=0
while IFS= read -r -d '' file; do
    path="${file#./}"

    if [ "$lfs_uploads" = "true" ]; then
        git lfs track "$path"
        continue
    fi

    # Only content that differs from HEAD adds anything to history this run.
    if git diff --quiet HEAD -- "$path" 2>/dev/null; then
        continue
    fi

    size="$(stat -c%s "$file")"
    raw+=("$(printf '%s (%s MiB)' "$path" "$((size / 1048576))")")
    raw_bytes=$((raw_bytes + size))
done < <(find . -mindepth 1 -type f -size +10M ! -path './.git*' ! -path './packscripts*' -print0)

if [ "${#raw[@]}" -gt 0 ]; then
    printf 'Committing raw (LFS uploads are off): %s\n' "${raw[@]}"
    {
        echo "### Large files committed raw"
        echo
        echo "LFS uploads are off, so $((raw_bytes / 1048576)) MiB of new large content goes into git history:"
        printf -- '- `%s`\n' "${raw[@]}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
