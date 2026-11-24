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
# Build a cuDF JNI artifact carrying the generalized `transform` binding.
#
# WHAT THIS IS FOR
#
#   libcudf's `cudf::transform_extended` has taken several input columns, a chosen output type and
#   null-aware execution for some time. The Java side has not: `ColumnView.transform(String,
#   boolean)` passes one column, always asks for INT32, and cannot ask for null-awareness at all.
#   That gap is the whole of NVIDIA's "opportunity #2". The patch beside this script adds the
#   missing Java method and its JNI entry point; everything else here is the machinery to build it
#   from NVIDIA's own pinned sources rather than from a hand-modified tree.
#
# WHAT IT BUILDS FROM
#
#   The pins are not guesses. They are read out of the released artifact: the properties files
#   inside com.nvidia:spark-rapids-jni:26.08.0:cuda12 name the exact revisions NVIDIA built it
#   from, and those are the two revisions below. The cuDF revision is not set here at all -- it is
#   the submodule pin of the JNI revision, so checking out one fixes the other.
#
#     spark-rapids-jni-version-info.properties -> url, revision  (the repo was renamed
#                                                 spark-rapids-jni -> cudf-spark-jni)
#     cudf-java-version-info.properties        -> url, revision  (thirdparty/cudf)
#
#   Everything below those -- CCCL, rmm, rapids-cmake, kvikio, cuco and the rest -- is pinned by
#   thirdparty/cudf-pins/versions.json inside the JNI revision, with a SHA256 or a git tag for
#   each. Nothing is resolved from a moving branch.
#
# WHAT IT PRODUCES
#
#   com.nvidia:spark-rapids-jni:${JNI_VERSION}:cuda12, installed into the local Maven repository.
#   The version is deliberately NOT 26.08.0: overwriting NVIDIA's released coordinates would make
#   it impossible to tell a jar with the wider API from one without, and would silently change what
#   every other build on the machine resolves.
#
# WHICH GPU IT BUILDS FOR  -- read this before overriding CMAKE_CUDA_ARCHITECTURES
#
#   libcudf's own kernels are compiled ahead of time, so the artifact only runs on the GPU
#   architectures it was built for. CUDA's PTX JIT goes *forward* only: a build for compute_89
#   runs on sm_90 and newer, and on nothing older. The failure is late and misleading -- the build
#   succeeds, the jar looks fine, the plugin starts, and the first query dies inside a Spark task
#   with "no kernel image is available for execution on the device".
#
#   So by default this script does NOT pick an architecture. It reads the compute capability of
#   the GPU in the machine it is running on and builds `<cap>-real;<cap>-virtual`: native SASS for
#   that GPU, plus PTX so the same artifact still runs on anything newer. Nothing is assumed about
#   whose machine this is.
#
#   Note that the UDF device functions this whole integration generates are compiled by NVRTC at
#   run time, for whatever GPU is actually present. They are not affected by any of this. What is
#   affected is libcudf itself -- its joins, sorts, aggregations and string kernels.
#
# WHAT IT COSTS
#
#   libcudf is built from source, statically, and linked into one shared object. On 20 cores that
#   is about 40 minutes and tens of gigabytes of scratch space for a single GPU architecture, and
#   considerably more for the nine NVIDIA ships.
#
# USAGE
#
#   ./build-cudf-spark-jni.sh [workdir]
#
#   Environment:
#     JNI_VERSION                 artifact version to produce (default 26.08.0-tcudf)
#     CMAKE_CUDA_ARCHITECTURES    unset (default): detect this machine's GPU, build for it and
#                                 for anything newer. Or a single bare architecture such as 80,
#                                 which means both real and virtual; or RAPIDS for everything
#                                 NVIDIA ships (portable, hours); or NATIVE to let rapids-cmake
#                                 detect inside the container. A semicolon-separated list is
#                                 refused: build/buildcpp.sh cannot carry one (see below).
#     ALLOW_ARCH_MISMATCH=1       build an architecture this machine's GPU cannot run, e.g. when
#                                 producing an artifact for a different machine
#     CPP_PARALLEL_LEVEL          parallel native compiles (default 8; each nvcc wants ~2-3 GiB)
#     CUDA_VERSION                toolkit for the build container (default 12.9.1, as NVIDIA's CI)
#     SKIP_BUILD=1                prepare the tree and stop, for inspecting what would be built

set -euo pipefail

# From spark-rapids-jni-version-info.properties of the released 26.08.0-cuda12 artifact.
JNI_REPO=${JNI_REPO:-https://github.com/NVIDIA/cudf-spark-jni.git}
JNI_REVISION=${JNI_REVISION:-761c184ff0a0dc5b678b1f5f163c579068beb133}
# From cudf-java-version-info.properties of the same artifact; also the submodule pin above.
EXPECTED_CUDF_REVISION=${EXPECTED_CUDF_REVISION:-ff5b362d7c06ae5837fd7a7337e2ae20895f324d}

JNI_VERSION=${JNI_VERSION:-26.08.0-tcudf}
CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES:-}
CPP_PARALLEL_LEVEL=${CPP_PARALLEL_LEVEL:-8}
CUDA_VERSION=${CUDA_VERSION:-12.9.1}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH="$HERE/cudf-transform-generalized-jni.patch"
WORKDIR=${1:-${WORKDIR:-$HOME/Projects/cudf-spark-jni}}

[ -f "$PATCH" ] || { echo "patch not found: $PATCH" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Which GPU architectures to build for, decided here rather than guessed.
# ---------------------------------------------------------------------------------------------

# The compute capability of the GPU in this machine, as two digits (8.9 -> 89), or empty.
detect_compute_cap() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null |
    head -1 | tr -d ' .' | grep -E '^[0-9]+$' || true
}

# Whether a requested architecture list can run on compute capability $2.
#
# An entry matches either exactly, as SASS (`80`, `80-real`), or from below, as PTX the driver
# JITs forward (`80`, `80-virtual` on an sm_90 card). It never matches from above: PTX does not
# JIT backwards, which is the whole trap this function exists to catch.
arch_list_covers() {
  local list=$1 cap=$2 entry num suffix
  case "$list" in
    RAPIDS|NATIVE|"") return 0 ;;
  esac
  for entry in ${list//;/ }; do
    num=${entry%%-*}
    suffix=${entry#"$num"}
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if [ "$num" -eq "$cap" ] && [ "$suffix" != "-virtual" ]; then return 0; fi
    if [ "$num" -le "$cap" ] && [ "$suffix" != "-real" ]; then return 0; fi
  done
  return 1
}

GPU_NAME=$(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
COMPUTE_CAP=$(detect_compute_cap)

# A semicolon-separated CMake list cannot be passed through this repository's build. buildcpp.sh
# writes CMAKE_CUDA_ARCHITECTURES into target/buildcpp-env.sh unquoted and sources it back, so the
# `;` separates shell commands instead. Caught here, with the alternatives, rather than 20 minutes
# later as "command not found".
case "$CMAKE_CUDA_ARCHITECTURES" in
  *\;*)
    echo >&2
    echo "ERROR: CMAKE_CUDA_ARCHITECTURES='$CMAKE_CUDA_ARCHITECTURES' contains a semicolon, which this" >&2
    echo "       build cannot carry: build/buildcpp.sh writes it to target/buildcpp-env.sh as an" >&2
    echo "       unquoted KEY=VALUE line and sources it, so bash reads the ';' as a command separator." >&2
    echo >&2
    echo "       A single bare architecture already means real and virtual, which is usually what" >&2
    echo "       was wanted:  CMAKE_CUDA_ARCHITECTURES=${COMPUTE_CAP:-80}" >&2
    echo "       For every architecture NVIDIA ships:  CMAKE_CUDA_ARCHITECTURES=RAPIDS" >&2
    echo >&2
    exit 1
    ;;
esac

if [ -z "$CMAKE_CUDA_ARCHITECTURES" ]; then
  if [ -n "$COMPUTE_CAP" ]; then
    # A bare number, not "<cap>-real;<cap>-virtual". The two mean the same thing to CMake -- an
    # entry with no suffix generates both real and virtual, which `cuobjdump -lelf`/`-lptx` on a
    # build for `89` confirms: sm_89 SASS and sm_89.ptx. But the semicolon form cannot survive
    # this repository's own build: buildcpp.sh writes its settings to target/buildcpp-env.sh as
    # unquoted KEY=VALUE lines and sources them back, so a `;` is read as a command separator and
    # the build dies with "80-virtual: command not found". Hence the bare form.
    CMAKE_CUDA_ARCHITECTURES="${COMPUTE_CAP}"
    echo "== GPU: ${GPU_NAME:-unknown} (compute capability ${COMPUTE_CAP})"
    echo "== building for $CMAKE_CUDA_ARCHITECTURES  (native SASS, plus PTX for newer GPUs)"
  else
    # No GPU detected -- no nvidia-smi, or a driver that cannot answer. This may be a build host
    # with no GPU at all. Guessing an architecture here is how an artifact that runs nowhere gets
    # produced, so build for everything instead and say that it will take much longer.
    CMAKE_CUDA_ARCHITECTURES=RAPIDS
    echo "== no GPU could be detected here, so the target architecture is unknown"
    echo "== building for RAPIDS (every architecture NVIDIA ships). This takes hours; set"
    echo "   CMAKE_CUDA_ARCHITECTURES explicitly if you know which GPU this artifact is for."
  fi
elif [ -n "$COMPUTE_CAP" ] && ! arch_list_covers "$CMAKE_CUDA_ARCHITECTURES" "$COMPUTE_CAP"; then
  echo >&2
  echo "ERROR: CMAKE_CUDA_ARCHITECTURES='$CMAKE_CUDA_ARCHITECTURES' produces an artifact that cannot" >&2
  echo "       run on this machine's GPU, ${GPU_NAME:-unknown} (compute capability $COMPUTE_CAP)." >&2
  echo >&2
  echo "       libcudf's kernels are compiled ahead of time and CUDA's PTX JIT only goes forward," >&2
  echo "       so this would build for ${CMAKE_CUDA_ARCHITECTURES} and then fail at the first query with" >&2
  echo "       'no kernel image is available for execution on the device' -- after the full build." >&2
  echo >&2
  echo "       For this GPU:   CMAKE_CUDA_ARCHITECTURES='${COMPUTE_CAP}-real;${COMPUTE_CAP}-virtual'" >&2
  echo "       Or simply leave CMAKE_CUDA_ARCHITECTURES unset, which does exactly that." >&2
  echo "       Building for another machine on purpose: ALLOW_ARCH_MISMATCH=1" >&2
  echo >&2
  [ "${ALLOW_ARCH_MISMATCH:-0}" = "1" ] || exit 1
  echo "ALLOW_ARCH_MISMATCH=1 given; continuing." >&2
else
  echo "== GPU: ${GPU_NAME:-unknown}${COMPUTE_CAP:+ (compute capability $COMPUTE_CAP)}"
  echo "== building for $CMAKE_CUDA_ARCHITECTURES (as requested)"
fi

echo "== cudf-spark-jni $JNI_REVISION -> $WORKDIR"
if [ ! -d "$WORKDIR/.git" ]; then
  git clone --filter=blob:none "$JNI_REPO" "$WORKDIR"
fi
cd "$WORKDIR"
# Switching an existing checkout to another revision must not carry -- or lose -- anyone's edits.
# The one tracked change this script makes itself is the version in pom.xml.
if [ "$(git rev-parse HEAD)" != "$JNI_REVISION" ]; then
  foreign=$(git status --porcelain --untracked-files=no --ignore-submodules=all | awk '$2 != "pom.xml"')
  if [ -n "$foreign" ]; then
    echo >&2 "REFUSING: $WORKDIR is not at $JNI_REVISION and has tracked changes this script did not make:"
    echo >&2 "$foreign"
    echo >&2 "Nothing was changed. Use a fresh work directory, or commit/stash those changes."
    exit 1
  fi
fi
git fetch origin "$JNI_REVISION"
git checkout --detach "$JNI_REVISION"

# NOT --reference. A borrowed object store leaves an `objects/info/alternates` pointing at a path
# outside the build container's bind mounts, and the build's own `git` calls then fail with
# "unable to normalize alternate object path" long after the clone looked fine.
git submodule update --init --depth 1 thirdparty/cudf
actual=$(git -C thirdparty/cudf rev-parse HEAD)
if [ "$actual" != "$EXPECTED_CUDF_REVISION" ]; then
  echo "cudf submodule is $actual, expected $EXPECTED_CUDF_REVISION" >&2
  exit 1
fi
echo "== cudf $actual (matches the released artifact)"

# Leave the cuDF submodule as the patch machinery expects to find it: pristine -- but only by
# undoing what the build itself did. See cudf-submodule-state.sh: it restores exactly the paths the
# staged patches account for, and refuses, changing nothing, if anything else has been edited.
# (The previous version ended in `git checkout -- .`, which discarded unrelated tracked edits.)
# shellcheck source=cudf-submodule-state.sh
source "$HERE/cudf-submodule-state.sh"
if ! restore_cudf_submodule thirdparty/cudf patches; then
  echo >&2 "The work directory was left exactly as it was. Clean the cuDF submodule by hand, or pass"
  echo >&2 "a fresh work directory as the first argument, and run this again."
  exit 1
fi

# The build applies patches/*.patch to the cuDF submodule before compiling and reverses them on
# `clean`, so dropping the patch in here is the supported way to carry a change: the submodule
# itself stays at its pinned revision and is never edited in place.
mkdir -p patches
cp "$PATCH" patches/0002-tornadovm-transform-generalized-jni.patch
echo "== patch staged as patches/0002-tornadovm-transform-generalized-jni.patch"

# A distinct version, so NVIDIA's released 26.08.0 in the local repository is never overwritten.
if ! grep -q "<version>$JNI_VERSION</version>" pom.xml; then
  perl -0pi -e "s{(<artifactId>spark-rapids-jni</artifactId>\s*\n\s*<version>)[^<]+(</version>)}{\${1}$JNI_VERSION\${2}}" pom.xml
fi
grep -m1 -A1 "<artifactId>spark-rapids-jni</artifactId>" pom.xml

[ "${SKIP_BUILD:-0}" = "1" ] && { echo "SKIP_BUILD=1, stopping before the build"; exit 0; }

export CUDA_VERSION
export PARALLEL_LEVEL=${PARALLEL_LEVEL:-$(nproc)}
export CMAKE_GENERATOR=${CMAKE_GENERATOR:-Ninja}

echo "== building (arch $CMAKE_CUDA_ARCHITECTURES, $CPP_PARALLEL_LEVEL parallel native compiles)"
./build/build-in-docker \
  -DCMAKE_CUDA_ARCHITECTURES="$CMAKE_CUDA_ARCHITECTURES" \
  -DCPP_PARALLEL_LEVEL="$CPP_PARALLEL_LEVEL" \
  -DskipTests \
  clean install

echo
# The Maven classifier follows the toolkit major version, the same way NVIDIA's build derives it.
echo "== installed com.nvidia:spark-rapids-jni:$JNI_VERSION:cuda${CUDA_VERSION%%.*}"
echo "   Point spark-jitudf at it with -Dcudf.jni.version=$JNI_VERSION, and put the jar ahead of"
echo "   the RAPIDS distribution on the class path: both carry ai.rapids.cudf, and only this one"
echo "   has the generalized ColumnView.transform."
