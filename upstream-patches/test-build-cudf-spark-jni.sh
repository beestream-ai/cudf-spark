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
# Runs the real build-cudf-spark-jni.sh -- not a copy of its logic -- against throwaway repositories
# that stand in for cudf-spark-jni and its cuDF submodule, with SKIP_BUILD=1 so that it stops just
# before the native build. Every state a work directory can be left in by an earlier build, an
# interrupted one or a developer is set up, and the script must either prepare it correctly or
# refuse, leaving every byte -- the staged patch, the saved patch state, the developer's files --
# exactly as it was.
#
# Nothing here touches a real checkout: every repository lives under one mktemp directory.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD="$HERE/build-cudf-spark-jni.sh"

ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT
PASS=0
FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); echo "  PASS  $1"; else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; fi
}

# Local file:// submodules and fetching a commit by id are off by default; allow them for these
# throwaway repositories only, through the environment, so no git configuration is changed.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=uploadpack.allowAnySHA1InWant GIT_CONFIG_VALUE_1=true
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.invalid

# --- the upstream stand-ins ----------------------------------------------------------------------
CUDF=$ROOT/upstream-cudf
mkdir -p "$CUDF/java"
git -C "$CUDF" init -q
printf 'native loader\n' > "$CUDF/java/NativeDepsLoader.java"
printf 'column view\nline two\n' > "$CUDF/java/ColumnView.java"
printf 'readme\n' > "$CUDF/README.md"
git -C "$CUDF" add -A && git -C "$CUDF" commit -q -m cudf
CUDF_REV=$(git -C "$CUDF" rev-parse HEAD)

# Patches built against it: NVIDIA's own (tracked in the JNI repository) and ours (the canonical).
printf 'native loader, static nvcomp\n' > "$CUDF/java/NativeDepsLoader.java"
NVIDIA_PATCH=$(git -C "$CUDF" diff)
git -C "$CUDF" checkout -q -- .
printf 'column view\nline two\ntransform(ColumnView[] ...)\n' > "$CUDF/java/ColumnView.java"
printf 'enum OutputNullability\n' > "$CUDF/java/OutputNullability.java"
git -C "$CUDF" add -N java/OutputNullability.java
CANONICAL=$ROOT/canonical.patch
git -C "$CUDF" diff > "$CANONICAL"
git -C "$CUDF" reset -q && git -C "$CUDF" checkout -q -- . && rm -f "$CUDF/java/OutputNullability.java"

JNI=$ROOT/upstream-jni
mkdir -p "$JNI/patches"
git -C "$JNI" init -q
printf '<project>\n  <artifactId>spark-rapids-jni</artifactId>\n  <version>26.08.0</version>\n</project>\n' > "$JNI/pom.xml"
printf '%s\n' "$NVIDIA_PATCH" > "$JNI/patches/0001-use-static-nvcomp.patch"
git -C "$JNI" add -A
git -C "$JNI" -c protocol.file.allow=always submodule add -q "file://$CUDF" thirdparty/cudf
git -C "$JNI" commit -q -m jni
JNI_REV=$(git -C "$JNI" rev-parse HEAD)

run_build() {
  JNI_REPO="file://$JNI" JNI_REVISION=$JNI_REV EXPECTED_CUDF_REVISION=$CUDF_REV TCUDF_PATCH=$CANONICAL \
    CMAKE_CUDA_ARCHITECTURES=NATIVE SKIP_BUILD=1 RESTORE_BACKUP_DIR="$1/backup-$RANDOM" bash "$BUILD" "$1" > "$1.out" 2>&1
}

# What spark-rapids-jni's build/apply-patches does to the submodule: every patch, then the state file.
jni_build_applies() {
  local w=$1 p
  for p in $(find "$w/patches" -maxdepth 1 -type f -name '*.patch' | sort -V); do
    git -C "$w/thirdparty/cudf" apply "$p"
  done
  git -C "$w/thirdparty/cudf" diff > "$w/thirdparty/cudf/spark-rapids-jni.patch"
}

snapshot() { (cd "$1" && find . -path ./.git -prune -o -path ./thirdparty/cudf/.git -prune -o -name 'backup-*' -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }
sub_clean() { [ -z "$(git -C "$1/thirdparty/cudf" status --porcelain --untracked-files=all)" ]; }
staged_is_canonical() { cmp -s "$CANONICAL" "$1/patches/0002-tornadovm-transform-generalized-jni.patch"; }

# A prepared work directory: built once from scratch.
prepared() {
  local w=$ROOT/$1
  run_build "$w" || { echo "  (setup build failed: $(tail -3 "$w.out"))"; }
  echo "$w"
}

# --- the cases ----------------------------------------------------------------------------------
echo "--- clean first build"
w=$ROOT/first
run_build "$w"
check "succeeds" "[ $? = 0 ]"
check "stages the canonical patch" "staged_is_canonical $w"
check "leaves the submodule pristine" "sub_clean $w"
check "sets the distinct version" "grep -q '<version>26.08.0-tcudf</version>' $w/pom.xml"

echo "--- repeated build, nothing applied"
w=$(prepared repeated)
run_build "$w"
check "succeeds" "[ $? = 0 ]"
check "reports the patch as already staged" "grep -q 'already staged' $w.out"
check "staged patch still canonical" "staged_is_canonical $w"

echo "--- rebuild after the JNI build applied every patch (and wrote its state file)"
w=$(prepared applied)
jni_build_applies "$w"
run_build "$w"
check "succeeds" "[ $? = 0 ]"
check "the submodule is restored, created file and state file gone" "sub_clean $w"
check "the removed files were backed up first" "ls $w/backup-*/files/spark-rapids-jni.patch >/dev/null 2>&1"

echo "--- interrupted patch application (only NVIDIA's patch applied, no state file)"
w=$(prepared interrupted)
git -C "$w/thirdparty/cudf" apply "$w/patches/0001-use-static-nvcomp.patch"
run_build "$w"
check "succeeds" "[ $? = 0 ] && sub_clean $w"

echo "--- repeated cleanup: two rebuilds in a row after a full application"
w=$(prepared twice)
jni_build_applies "$w"
run_build "$w"; first=$?
run_build "$w"; second=$?
check "both succeed and end pristine" "[ $first = 0 ] && [ $second = 0 ] && sub_clean $w"

echo "--- a modified staged patch is refused, and nothing is touched"
w=$(prepared staged-edit)
jni_build_applies "$w"
printf '# my change to the binding\n' >> "$w/patches/0002-tornadovm-transform-generalized-jni.patch"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q 'differs from the canonical' $w.out"
check "every byte is unchanged (staged patch, applied submodule, state file)" "[ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- an interrupted staging file is preserved"
w=$(prepared stage-part)
staged="$w/patches/0002-tornadovm-transform-generalized-jni.patch"
mv -- "$staged" "$staged.part"
printf 'local edit\n' >> "$staged.part"
before=$(snapshot "$w")
run_build "$w"
check "refuses and preserves the interrupted patch" "[ $? != 0 ] && [ \"\$(snapshot $w)\" = \"$before\" ]"

echo "--- a hand-edited hunk in the saved state file is refused, and nothing is touched"
w=$(prepared state-edit)
jni_build_applies "$w"
sed -i 's/transform(ColumnView\[\] ...)/transform(ColumnView[] ..., mine)/' "$w/thirdparty/cudf/spark-rapids-jni.patch"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q 'not the diff the build' $w.out"
check "every byte is unchanged" "[ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- a modified hunk within a patched file is refused, and nothing is touched"
w=$(prepared hunk-edit)
jni_build_applies "$w"
printf 'my experiment\n' >> "$w/thirdparty/cudf/java/ColumnView.java"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ]"
check "every byte is unchanged" "[ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- an unexpected tracked edit elsewhere is refused, and nothing is touched"
w=$(prepared tracked-edit)
printf 'notes\n' >> "$w/thirdparty/cudf/README.md"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q README.md $w.out"
check "every byte is unchanged" "[ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- an unexpected untracked file is refused, and nothing is touched"
w=$(prepared untracked)
jni_build_applies "$w"
printf 'scratch\n' > "$w/thirdparty/cudf/java/Scratch.java"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q Scratch.java $w.out"
check "every byte is unchanged, the stray file included" "[ \"\$(snapshot $w)\" = \"\$before\" ] && [ -f $w/thirdparty/cudf/java/Scratch.java ]"

echo "--- expected additive files left behind on their own are removed"
w=$(prepared additive)
jni_build_applies "$w"
git -C "$w/thirdparty/cudf" apply -R "$w/thirdparty/cudf/spark-rapids-jni.patch"
rm -f "$w/thirdparty/cudf/spark-rapids-jni.patch"
run_build "$w"
check "succeeds and the leftover created file is gone" "[ $? = 0 ] && sub_clean $w"

echo "--- an edited project version in pom.xml is refused, and nothing is touched"
w=$(prepared pom-version)
sed -i 's#<version>26.08.0-tcudf</version>#<version>26.08.0-mine</version>#' "$w/pom.xml"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q 'pom.xml has changes this script did not make' $w.out"
check "the edited version survives, and every byte is unchanged" "grep -q '26.08.0-mine' $w/pom.xml && [ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- an unrelated pom.xml edit is refused, and nothing is touched"
w=$(prepared pom-other)
printf '<!-- my local build setting -->\n' >> "$w/pom.xml"
before=$(snapshot "$w")
run_build "$w"
check "refuses" "[ $? != 0 ] && grep -q 'pom.xml has changes this script did not make' $w.out"
check "every byte is unchanged" "[ \"\$(snapshot $w)\" = \"\$before\" ]"

echo "--- the script's own version edit is recognised on a rerun"
w=$(prepared pom-own)
run_build "$w"
check "succeeds and reports the version as already set" "[ $? = 0 ] && grep -q 'already the pinned file with version 26.08.0-tcudf' $w.out"

echo "--- moving to a new pinned revision undoes only the script's own pom.xml edit"
w=$(prepared pom-move)
printf 'release notes\n' > "$JNI/NOTES"
git -C "$JNI" add NOTES && git -C "$JNI" commit -q -m "next revision"
OLD_REV=$JNI_REV
JNI_REV=$(git -C "$JNI" rev-parse HEAD)
run_build "$w"
moved=$?
check "succeeds at the new revision with the version set again" "[ $moved = 0 ] && [ \"\$(git -C $w rev-parse HEAD)\" = $JNI_REV ] && grep -q '<version>26.08.0-tcudf</version>' $w/pom.xml"
JNI_REV=$OLD_REV

echo
echo "=== CHECKS: $((PASS + FAIL)), FAILURES: $FAIL ==="
[ "$FAIL" = 0 ]
