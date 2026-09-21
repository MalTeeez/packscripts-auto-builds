#!/usr/bin/env bash
# Rebuild .gitattributes so every large file is committed as a Git LFS pointer.
#
# With LFS_UPLOADS=false the pointers are still committed, but the objects are
# never pushed. That stays usable because packscripts reads the real sha256 and
# size straight out of the pointer: a mod whose annotated source is a GitHub
# release gets that release as its manifest url, with the (now dead) LFS url
# demoted to mirror_url. A large file without a release link only keeps working
# while its content is unchanged, since an earlier run already uploaded that
# exact object — anything newly pointered is reported at the end of this script.
#
# The starter zips are the exception: they are what the README hands users and
# they have no release to fall back on, so they are committed raw instead.
set -euo pipefail

lfs_uploads="${LFS_UPLOADS:-true}"
pack_name="$(jq -r '.PACKAGING.PACK_NAME' packscripts.json)"

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

find_args=(. -mindepth 1 -type f -size +10M ! -path './.git*' ! -path './packscripts*')

if [ "$lfs_uploads" != "true" ]; then
    # Only excludes a zip that already holds real content; before `package
    # bundle` runs it is still the previous run's pointer text, well under 10M.
    find_args+=(! -path "./${pack_name}-"'*.zip')
fi

unbacked=()
while IFS= read -r -d '' file; do
    path="${file#./}"
    git lfs track "$path"

    if [ "$lfs_uploads" = "true" ]; then
        continue
    fi

    source_url="$(jq -r --arg p "$file" 'to_entries[] | .value | select(.file_path == $p) | .source // ""' annotated_mods.json)"
    case "$source_url" in
        https://github.com/*/*/releases/download/*) continue ;;
    esac

    # No release to fall back on — fine as long as this content was already
    # pushed to LFS by an earlier run, i.e. the committed pointer still matches.
    committed_oid="$(git cat-file -p "HEAD:$path" 2>/dev/null | sed -n 's/^oid sha256://p' || true)"
    if [ -n "$committed_oid" ] && [ "$committed_oid" = "$(sha256sum "$file" | cut -d' ' -f1)" ]; then
        continue
    fi

    unbacked+=("$path")
done < <(find "${find_args[@]}" -print0)

if [ "$lfs_uploads" != "true" ]; then
    # Insurance against a git-lfs that reinstalls the hook anyway.
    neutralize_pre_push
fi

if [ "${#unbacked[@]}" -gt 0 ]; then
    printf 'W: no working download url while LFS uploads are off: %s\n' "${unbacked[@]}"
    {
        echo "### Large files with no download url"
        echo
        echo "LFS uploads are off and these have no release to fall back on:"
        printf -- '- `%s`\n' "${unbacked[@]}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
