#!/usr/bin/env bash
#
# Copyright (c) 2026 Beestream Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Restores the cuDF submodule to its pinned revision -- but only when every change in it is one the
# build itself made, and only those changes.
#
# Sourced by build-cudf-spark-jni.sh, and by test-cudf-submodule-state.sh, which exercises it on
# disposable fixtures. Nothing here runs on its own.
#
# WHY IT IS NOT `git checkout -- .`
#
#   The build applies patches/*.patch to the submodule and saves the combined diff as
#   spark-rapids-jni.patch. A rebuild needs the submodule back at its pin first, and a patch that
#   adds files cannot be fully reversed by the build's own un-patch step (a `git diff` of tracked
#   files never contains them). The previous version of this script therefore un-patched, ignored
#   any failure, and ran `git checkout -- .` -- which discards every tracked edit in the submodule,
#   whoever made it. A developer's unrelated change to cuDF vanished silently, and the cleanliness
#   check that followed could not notice, because by then it was gone.
#
# WHAT IT DOES INSTEAD
#
#   The changes the build can have made are known exactly: applying the first k of
#   patches/*.patch, in the build's own order, for some k, plus the saved state file. So:
#
#   1. Every changed or untracked path must be one the patches touch (or the state file). Anything
#      else -- an edit elsewhere, a stray file, a staged change -- is someone else's work.
#   2. The submodule's content must equal HEAD with the first k patches applied, for some k,
#      compared through a temporary index so that nothing is written while checking. A file the
#      patches create may also be left over on its own (the additive-patch case), but only with
#      exactly the content the patch gives it.
#   3. The saved state file, if present, must be exactly what apply-patches writes after applying
#      every patch: `git diff` of the fully patched tree. That is compared by content -- its
#      `git patch-id --stable` against the same diff rebuilt in a temporary index -- not by the
#      paths it mentions. A state file whose hunks were edited by hand names the same paths and is
#      someone's work; it is refused, not deleted.
#   4. Only then are those named paths restored: tracked ones from HEAD, created ones removed. If
#      RESTORE_BACKUP_DIR is set, every file about to be removed or overwritten is first copied
#      there, so even a restore that was justified can be inspected afterwards.
#
#   If any check fails, nothing is changed and the caller is told to sort it out. A refusal is the
#   correct result for a tree this script cannot account for; a reset is not.

# restore_cudf_submodule <submodule-dir> <patch-dir>
#   0: the submodule is clean (it was, or it has been restored); 1: refused, nothing changed.
#   With CHECK_ONLY=1 it stops after the checks and reports what it would restore, changing nothing.
restore_cudf_submodule() {
  local sub=$1 patch_dir
  # Absolute, because every git call below runs inside the submodule (git -C), where a relative
  # patch directory would resolve to nothing -- and an empty patch set explains no change at all.
  patch_dir=$(cd "$2" && pwd) || { echo >&2 "REFUSING: patch directory $2 does not exist"; return 1; }
  local state_file="spark-rapids-jni.patch"

  if [ -z "$(git -C "$sub" status --porcelain --untracked-files=all)" ]; then
    return 0
  fi

  if ! git -C "$sub" diff --cached --quiet; then
    echo >&2 "REFUSING: the cuDF submodule has staged changes, which the build never makes:"
    git -C "$sub" diff --cached --name-status >&2
    return 1
  fi

  local patches=()
  local p
  while IFS= read -r -d '' p; do
    patches+=("$p")
  done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -not -empty -print0 | sort -zV)

  # Every path the build's patches touch, and the subset they create.
  local touched created
  touched=$(for p in "${patches[@]}"; do git -C "$sub" apply --numstat "$p" | cut -f3-; done | sort -u)
  if [ ${#patches[@]} -gt 0 ] && [ -z "$touched" ]; then
    echo >&2 "REFUSING: the patches in $patch_dir could not be read, so no change can be accounted for"
    return 1
  fi
  created=$(for p in "${patches[@]}"; do
    awk '/^new file mode/ { want = 1 } want && /^\+\+\+ b\// { sub(/^\+\+\+ b\//, ""); print; want = 0 }' "$p"
  done | sort -u)

  # 1. Nothing outside the patches' paths, and the state file only if it describes those paths.
  local changed path unexplained=""
  changed=$( (git -C "$sub" diff --name-only; git -C "$sub" ls-files --others --exclude-standard) | sort -u)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "$path" = "$state_file" ]; then
      local described
      described=$(sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$sub/$state_file" | sort -u)
      if [ -n "$(comm -23 <(echo "$described") <(echo "$touched"))" ]; then
        unexplained+="$path (describes paths the patches do not touch)"$'\n'
      fi
      continue
    fi
    if ! grep -qxF -- "$path" <<< "$touched"; then
      unexplained+="$path"$'\n'
    fi
  done <<< "$changed"
  if [ -n "$unexplained" ]; then
    echo >&2 "REFUSING: the cuDF submodule has changes this build did not make; nothing was changed:"
    printf '%s' "$unexplained" | sed '/^$/d; s/^/  /' >&2
    echo >&2 "  Commit, stash or move them, or build in a fresh work directory."
    return 1
  fi

  # 2. The content must be HEAD plus the first k patches, for some k.
  local index matched=-1 k
  index=$(mktemp)
  for ((k = ${#patches[@]}; k >= 0; k--)); do
    GIT_INDEX_FILE=$index git -C "$sub" read-tree HEAD
    local ok=1 i
    for ((i = 0; i < k; i++)); do
      GIT_INDEX_FILE=$index git -C "$sub" apply --cached "${patches[$i]}" 2>/dev/null || { ok=0; break; }
    done
    [ $ok = 1 ] || continue
    # Tracked paths the patches touch must match this state exactly ...
    local tracked_ok=1
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if grep -qxF -- "$path" <<< "$created"; then
        continue
      fi
      if ! GIT_INDEX_FILE=$index git -C "$sub" diff --quiet -- "$path"; then
        tracked_ok=0
        break
      fi
    done <<< "$touched"
    [ $tracked_ok = 1 ] || continue
    # ... and every created file present must have the content the full patch set gives it.
    matched=$k
    break
  done
  if [ $matched -ge 0 ]; then
    local full full_ok=1
    full=$(mktemp)
    GIT_INDEX_FILE=$full git -C "$sub" read-tree HEAD
    for p in "${patches[@]}"; do
      GIT_INDEX_FILE=$full git -C "$sub" apply --cached "$p" 2>/dev/null || full_ok=0
    done
    # 3. The state file is apply-patches' `git diff` of the fully patched tree: tracked paths only,
    #    so a file a patch creates (untracked when it was written) is not in it.
    if [ -e "$sub/$state_file" ]; then
      local expected_id actual_id
      if [ $full_ok != 1 ]; then
        echo >&2 "REFUSING: the patches do not apply together, so $state_file cannot be shown to be the build's own; nothing was changed."
        rm -f "$index" "$full"
        return 1
      fi
      local excludes=()
      while IFS= read -r path; do
        [ -n "$path" ] && excludes+=(":(exclude)$path")
      done <<< "$created"
      expected_id=$(GIT_INDEX_FILE=$full git -C "$sub" diff --cached HEAD -- . "${excludes[@]}" | git -C "$sub" patch-id --stable | awk '{print $1}')
      actual_id=$(git -C "$sub" patch-id --stable < "$sub/$state_file" | awk '{print $1}')
      if [ "$expected_id" != "$actual_id" ]; then
        echo >&2 "REFUSING: $state_file in the cuDF submodule is not the diff the build's patches produce"
        echo >&2 "  (patch-id ${actual_id:-<none>}, expected ${expected_id:-<none>}): its hunks were edited, or it"
        echo >&2 "  belongs to another patch set. It is somebody's work, and nothing was changed."
        rm -f "$index" "$full"
        return 1
      fi
    fi
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -e "$sub/$path" ] || continue
      local want have
      want=$(GIT_INDEX_FILE=$full git -C "$sub" ls-files -s -- "$path" | awk '{print $2}')
      have=$(git -C "$sub" hash-object -- "$path")
      if [ "$want" != "$have" ]; then
        echo >&2 "REFUSING: $path is one the patch creates, but its content has been edited since; nothing was changed."
        rm -f "$index" "$full"
        return 1
      fi
    done <<< "$created"
    rm -f "$full"
  fi
  rm -f "$index"
  if [ $matched -lt 0 ]; then
    echo >&2 "REFUSING: files the patches touch have been edited beyond what the patches do; nothing was changed:"
    git -C "$sub" status --short >&2
    return 1
  fi

  # 4. Restore exactly those paths.
  echo "== the cuDF submodule carries the build's own patches ($matched of ${#patches[@]} applied); restoring only those paths"
  if [ "${CHECK_ONLY:-0}" = "1" ]; then
    echo "   CHECK_ONLY=1: verified, nothing changed"
    return 0
  fi
  if [ -n "${RESTORE_BACKUP_DIR:-}" ]; then
    mkdir -p "$RESTORE_BACKUP_DIR" || { echo >&2 "REFUSING: cannot create $RESTORE_BACKUP_DIR; nothing was changed"; return 1; }
    git -C "$sub" diff > "$RESTORE_BACKUP_DIR/tracked.diff"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if [ -e "$sub/$path" ]; then
        mkdir -p "$RESTORE_BACKUP_DIR/files/$(dirname "$path")"
        cp -p -- "$sub/$path" "$RESTORE_BACKUP_DIR/files/$path"
      fi
    done <<< "$(printf '%s\n%s\n' "$touched" "$state_file")"
    echo "   backed up what is about to change in $RESTORE_BACKUP_DIR"
  fi
  local restore=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if grep -qxF -- "$path" <<< "$created"; then
      if [ -e "$sub/$path" ]; then
        echo "   removing $path (created by a patch)"
        rm -f -- "$sub/$path"
      fi
    elif ! git -C "$sub" diff --quiet -- "$path"; then
      restore+=("$path")
    fi
  done <<< "$touched"
  if [ ${#restore[@]} -gt 0 ]; then
    printf '   restoring %s from HEAD\n' "${restore[@]}"
    git -C "$sub" checkout HEAD -- "${restore[@]}"
  fi
  if [ -f "$sub/$state_file" ]; then
    echo "   removing $state_file (the build's saved patch state)"
    rm -f -- "$sub/$state_file"
  fi

  if [ -n "$(git -C "$sub" status --porcelain --untracked-files=all)" ]; then
    echo >&2 "ERROR: the cuDF submodule is still not clean after restoring the patches' paths:"
    git -C "$sub" status --short >&2
    return 1
  fi
  echo "   submodule restored to $(git -C "$sub" rev-parse --short HEAD)"
  return 0
}
