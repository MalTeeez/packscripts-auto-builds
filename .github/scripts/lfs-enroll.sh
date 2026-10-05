#!/usr/bin/env bash
# Rebuild .gitattributes, deciding per large file whether it can be a Git LFS
# pointer or has to be committed as plain bytes.
#
# With LFS_UPLOADS=false nothing may be uploaded, and GitHub refuses a push that
# references an LFS object it does not already store (GH008, enforced from the
# pointer *content* — leaving the path out of .gitattributes does not help). So a
# large file may only stay an LFS pointer when its content is byte-identical to
# the pointer already committed at HEAD, i.e. an earlier run uploaded that exact
# object. Anything new is committed raw, which costs repo size but keeps every
# url working: packscripts hashes the blob content, so a raw jar still matches
# annotated_mods.json and its manifest url stays the GitHub release, with
# raw.githubusercontent as a mirror that now actually resolves.
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
    git config --local filter.lfs.clean 'git-lfs clean -- %f'
    git config --local filter.lfs.smudge 'git-lfs smudge -- %f'
    git config --local filter.lfs.process 'git-lfs filter-process'
    git config --local filter.lfs.required true
    export GIT_LFS_TRACK_NO_INSTALL_HOOKS=1
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

    # Unchanged content keeps its pointer: the object is already on the server,
    # so the push references nothing new. Everything else goes in raw.
    committed_oid="$(git cat-file -p "HEAD:$path" 2>/dev/null | sed -n 's/^oid sha256://p' || true)"
    if [ -n "$committed_oid" ] && [ "$committed_oid" = "$(sha256sum "$file" | cut -d' ' -f1)" ]; then
        git lfs track "$path"
        continue
    fi

    size="$(stat -c%s "$file")"
    raw+=("$(printf '%s (%s MiB)' "$path" "$((size / 1048576))")")
    raw_bytes=$((raw_bytes + size))
done < <(find . -mindepth 1 -type f -size +10M ! -path './.git*' ! -path './packscripts*' -print0)

if [ "$lfs_uploads" != "true" ]; then
    # Insurance against a git-lfs that reinstalls the hook anyway.
    neutralize_pre_push
fi

if [ "${#raw[@]}" -gt 0 ]; then
    printf 'Committing raw (LFS uploads are off): %s\n' "${raw[@]}"
    {
        echo "### Large files committed raw"
        echo
        echo "LFS uploads are off, so $((raw_bytes / 1048576)) MiB of new large content goes into git history:"
        printf -- '- `%s`\n' "${raw[@]}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
