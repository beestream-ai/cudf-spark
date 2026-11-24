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
# Exercises cudf-submodule-state.sh on disposable fixtures: a small git repository standing in for
# the cuDF submodule, a modifying patch (like NVIDIA's 0001) and an additive one (like ours, which
# creates two files). Every case checks both the return code and that nobody else's change was lost.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cudf-submodule-state.sh
source "$HERE/cudf-submodule-state.sh"

ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT
PASS=0
FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); echo "  PASS  $1"; else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; fi
}

# A fresh fixture: sub/ at a commit, and patches/ holding the two patches built against it.
fixture() {
  local dir=$ROOT/$1
  mkdir -p "$dir/sub/java" "$dir/patches"
  git -C "$dir/sub" init -q
  git -C "$dir/sub" config user.email t@example.invalid
  git -C "$dir/sub" config user.name test
  printf 'native loader\n' > "$dir/sub/java/NativeDepsLoader.java"
  printf 'column view\nline two\n' > "$dir/sub/java/ColumnView.java"
  printf 'readme\n' > "$dir/sub/README.md"
  printf 'target/\n' > "$dir/sub/.gitignore"
  git -C "$dir/sub" add -A && git -C "$dir/sub" commit -q -m base
  # 0001: modifies a tracked file.
  printf 'native loader, static nvcomp\n' > "$dir/sub/java/NativeDepsLoader.java"
  git -C "$dir/sub" diff > "$dir/patches/0001-static-nvcomp.patch"
  git -C "$dir/sub" checkout -q -- java/NativeDepsLoader.java
  # 0002: modifies a tracked file and creates two.
  printf 'column view\nline two\ntransform(ColumnView[] ...)\n' > "$dir/sub/java/ColumnView.java"
  printf 'enum OutputNullability\n' > "$dir/sub/java/OutputNullability.java"
  printf 'class TransformMultiTest\n' > "$dir/sub/java/TransformMultiTest.java"
  git -C "$dir/sub" add -N java/OutputNullability.java java/TransformMultiTest.java
  git -C "$dir/sub" diff > "$dir/patches/0002-generalized-jni.patch"
  git -C "$dir/sub" reset -q
  git -C "$dir/sub" checkout -q -- java/ColumnView.java
  rm -f -- "$dir/sub/java/OutputNullability.java" "$dir/sub/java/TransformMultiTest.java"
  echo "$dir"
}

# What the build's apply-patches does: every patch in order, then the saved combined diff.
build_applies() {
  local dir=$1 p
  for p in "$dir"/patches/0001-static-nvcomp.patch "$dir"/patches/0002-generalized-jni.patch; do
    git -C "$dir/sub" apply "$p"
  done
  git -C "$dir/sub" diff > "$dir/sub/spark-rapids-jni.patch"
}

clean() { [ -z "$(git -C "$1/sub" status --porcelain --untracked-files=all)" ]; }

# Every file of the submodule's working tree (not .git), with its content hash: a refusal must leave
# this exactly as it found it.
snapshot() { (cd "$1/sub" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }

echo "--- a clean checkout is left alone"
d=$(fixture clean)
restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "still clean" "clean $d"

echo "--- the build's own patches, fully applied"
d=$(fixture applied)
build_applies "$d"
restore_cudf_submodule "$d/sub" "$d/patches"
check "returns success" "[ $? = 0 ]"
check "restored to clean, created files and state file gone" "clean $d"

echo "--- only the first patch applied (an interrupted build)"
d=$(fixture partial)
git -C "$d/sub" apply "$d/patches/0001-static-nvcomp.patch"
restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "restored to clean" "clean $d"

echo "--- additive leftovers after the build's own un-patch step"
d=$(fixture leftovers)
build_applies "$d"
git -C "$d/sub" apply -R "$d/sub/spark-rapids-jni.patch" 2>/dev/null || true
rm -f -- "$d/sub/spark-rapids-jni.patch"
restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "the created files are removed" "clean $d"

echo "--- an unrelated tracked edit is refused and kept"
d=$(fixture foreign-tracked)
build_applies "$d"
printf 'my own notes\n' >> "$d/sub/README.md"
restore_cudf_submodule "$d/sub" "$d/patches" 2> "$d/err" > /dev/null
check "refuses" "[ $? = 1 ]"
check "names the file" "grep -q README.md $d/err"
check "the developer's edit survives" "grep -q 'my own notes' $d/sub/README.md"
check "the build's patches are left in place too" "grep -q static $d/sub/java/NativeDepsLoader.java"

echo "--- an edit on top of a patched file is refused and kept"
d=$(fixture edited-patched)
build_applies "$d"
printf 'a local experiment\n' >> "$d/sub/java/ColumnView.java"
restore_cudf_submodule "$d/sub" "$d/patches" 2> /dev/null > /dev/null
check "refuses" "[ $? = 1 ]"
check "the edit survives" "grep -q 'a local experiment' $d/sub/java/ColumnView.java"

echo "--- an edited patch-created file is refused and kept"
d=$(fixture edited-created)
build_applies "$d"
printf 'more\n' >> "$d/sub/java/OutputNullability.java"
restore_cudf_submodule "$d/sub" "$d/patches" 2> /dev/null > /dev/null
check "refuses" "[ $? = 1 ]"
check "the edit survives" "grep -q more $d/sub/java/OutputNullability.java"

echo "--- an unexpected untracked file is refused and kept"
d=$(fixture foreign-untracked)
build_applies "$d"
printf 'scratch\n' > "$d/sub/java/Scratch.java"
restore_cudf_submodule "$d/sub" "$d/patches" 2> "$d/err" > /dev/null
check "refuses" "[ $? = 1 ]"
check "names the file" "grep -q Scratch.java $d/err"
check "the file survives" "[ -f $d/sub/java/Scratch.java ]"

echo "--- a staged change is refused and kept"
d=$(fixture staged)
printf 'staged\n' >> "$d/sub/README.md"
git -C "$d/sub" add README.md
restore_cudf_submodule "$d/sub" "$d/patches" 2> /dev/null > /dev/null
check "refuses" "[ $? = 1 ]"
check "the staged change survives" "git -C $d/sub diff --cached --quiet; [ \$? = 1 ]"

echo "--- ignored build output does not count as a change"
d=$(fixture ignored)
mkdir -p "$d/sub/target" && printf 'object\n' > "$d/sub/target/x.o"
restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "the ignored file is untouched" "[ -f $d/sub/target/x.o ]"

echo "--- a relative patch directory, as the build script passes it"
d=$(fixture relative)
build_applies "$d"
( cd "$d" && restore_cudf_submodule sub patches > /dev/null )
check "returns success" "[ $? = 0 ]"
check "restored to clean" "clean $d"

echo "--- repeated builds and repeated cleans"
d=$(fixture repeated)
ok=1
for round in 1 2 3; do
  build_applies "$d" || ok=0
  restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null || ok=0
  clean "$d" || ok=0
  restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null || ok=0
done
check "three apply/restore/restore rounds all succeed and end clean" "[ $ok = 1 ] && clean $d"

echo "--- CHECK_ONLY verifies without changing anything"
d=$(fixture check-only)
build_applies "$d"
before=$(git -C "$d/sub" status --porcelain --untracked-files=all)
CHECK_ONLY=1 restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "nothing changed" "[ \"\$(git -C $d/sub status --porcelain --untracked-files=all)\" = \"$before\" ]"

echo "--- Codex: a hand-edited hunk in the saved patch, touching only allowed paths, is refused and kept"
d=$(fixture edited-state)
build_applies "$d"
sed -i 's/transform(ColumnView\[\] ...)/transform(ColumnView[] ..., my own change)/' "$d/sub/spark-rapids-jni.patch"
grep -q 'my own change' "$d/sub/spark-rapids-jni.patch" || echo "  (fixture did not edit the hunk)"
before=$(snapshot "$d")
restore_cudf_submodule "$d/sub" "$d/patches" 2> "$d/err" > /dev/null
check "refuses" "[ $? = 1 ]"
check "says the saved patch is not the build's" "grep -q 'not the diff the build' $d/err"
check "every file, the saved patch included, is byte-identical" "[ \"\$(snapshot $d)\" = \"\$before\" ]"

echo "--- a saved patch from another patch set, on an otherwise clean tree, is refused and kept"
d=$(fixture foreign-state)
printf 'diff --git a/java/ColumnView.java b/java/ColumnView.java\n--- a/java/ColumnView.java\n+++ b/java/ColumnView.java\n@@ -1 +1 @@\n-column view\n+someone else\n' > "$d/sub/spark-rapids-jni.patch"
before=$(snapshot "$d")
restore_cudf_submodule "$d/sub" "$d/patches" 2> /dev/null > /dev/null
check "refuses" "[ $? = 1 ]"
check "byte-identical" "[ \"\$(snapshot $d)\" = \"\$before\" ]"

echo "--- a stale but genuine saved patch with only the first patch applied is the build's own"
d=$(fixture stale-state)
build_applies "$d"
saved=$(cat "$d/sub/spark-rapids-jni.patch")
git -C "$d/sub" apply -R "$d/patches/0002-generalized-jni.patch"
printf '%s\n' "$saved" > "$d/sub/spark-rapids-jni.patch"
restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ]"
check "restored to clean" "clean $d"

echo "--- refusals leave every earlier fixture byte-identical"
for kind in tracked patched created untracked; do
  d=$(fixture "bytes-$kind")
  build_applies "$d"
  case $kind in
    tracked) printf 'mine\n' >> "$d/sub/README.md" ;;
    patched) printf 'mine\n' >> "$d/sub/java/ColumnView.java" ;;
    created) printf 'mine\n' >> "$d/sub/java/OutputNullability.java" ;;
    untracked) printf 'mine\n' > "$d/sub/java/Mine.java" ;;
  esac
  before=$(snapshot "$d")
  restore_cudf_submodule "$d/sub" "$d/patches" 2> /dev/null > /dev/null
  rc=$?
  check "$kind: refuses and changes no byte" "[ $rc = 1 ] && [ \"\$(snapshot $d)\" = \"\$before\" ]"
done

echo "--- RESTORE_BACKUP_DIR keeps a copy of everything a justified restore removes"
d=$(fixture backup)
build_applies "$d"
RESTORE_BACKUP_DIR="$d/backup" restore_cudf_submodule "$d/sub" "$d/patches" > /dev/null
check "returns success" "[ $? = 0 ] && clean $d"
check "the saved patch was backed up" "[ -s $d/backup/files/spark-rapids-jni.patch ]"
check "a created file was backed up" "grep -q OutputNullability $d/backup/files/java/OutputNullability.java"
check "the tracked diff was backed up" "grep -q 'static nvcomp' $d/backup/tracked.diff"

echo
echo "=== CHECKS: $((PASS + FAIL)), FAILURES: $FAIL ==="
[ "$FAIL" = 0 ]
