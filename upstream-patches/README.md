# Generalized cuDF `transform` JNI binding

A patch to NVIDIA's cuDF Java binding (in `cudf-spark-jni`) that exposes libcudf's
`cudf::transform_extended` with several input columns, a chosen output type, null-aware execution
and an output-nullability policy, plus a build helper that applies it to NVIDIA's pinned sources.

It was written for [spark-jitudf](https://github.com/beestream-ai/spark-jitudf), whose compiled
UDFs need all four features, but it does not depend on TornadoVM or on spark-jitudf. It could
equally serve hand-written `RapidsUDF`s. It is offered here for evaluation; it has not been proposed
upstream.

| File | Purpose |
|---|---|
| `cudf-transform-generalized-jni.patch` | The patch (Java API, JNI entry point, tests). Its header explains the change in full. |
| `build-cudf-spark-jni.sh` | Clones NVIDIA's `cudf-spark-jni` at the pinned revision, stages the patch and builds `com.nvidia:spark-rapids-jni:26.08.0-tcudf` in NVIDIA's build container. |
| `cudf-submodule-state.sh` | Sourced by the build helper: restores the cuDF submodule between builds, touching only what an earlier build changed. |
| `test-build-cudf-spark-jni.sh`, `test-cudf-submodule-state.sh` | Fixture tests for the two scripts on disposable repositories (24 and 44 checks). They never touch a real checkout. |

## What the patch adds

**Java** (`ai.rapids.cudf`):

```java
public static ColumnVector ColumnView.transform(ColumnView[] inputs, String udf, boolean isPtx,
                                                DType outputType, boolean isNullAware,
                                                OutputNullability outputNullability)

public enum OutputNullability { PRESERVE, ALL_VALID }   // mirrors cudf::output_nullability
```

**JNI**: `Java_ai_rapids_cudf_ColumnView_transformMulti`, Java descriptor
`([JLjava/lang/String;ZIIZI)J`. It builds one `cudf::transform_input` per column view and calls
`cudf::transform_extended(inputs, udf, data_type(type, scale), CUDA|PTX, nullopt,
null_aware::YES|NO, nullopt, output_nullability)`.

Nothing else changes. The existing `ColumnView.transform(String, boolean)` overload and its JNI
entry point are untouched, there is no new C++ algorithm, and error reporting is unchanged.

**Semantics** (defined by libcudf; the binding only exposes them):

| Feature | Behavior |
|---|---|
| Inputs | One or more columns of equal row count (validated by libcudf). Fixed-width types. |
| Output | Any fixed-width `DType` libcudf's transform supports; tested: INT32, INT64, FLOAT32, FLOAT64, BOOL8, from mixed input types. |
| Device function shape | `__device__ void f(OUT* out, IN0 in0, IN1 in1, ...)`; null-aware: `__device__ void f(cuda::std::optional<OUT>* out, cuda::std::optional<IN0> in0, ...)`. The output pointer comes first and inputs follow in column order. libcudf renames the first identifier before `(`, so the entry point must be the first function in the source. |
| `isNullAware=false` | The function is not called for rows under a null (with `PRESERVE`), and the output mask is the intersection of the input masks. |
| `isNullAware=true` | The function receives optionals and decides; the output's validity is what it set. PTX cannot be null-aware. |
| `OutputNullability.PRESERVE` | Always correct. |
| `OutputNullability.ALL_VALID` | An optimization with a precondition the binding cannot check: every row produces a value. No mask is allocated, and with a null-unaware function rows under a null are not skipped. |
| Error channel | A function may return an integer instead of `void`. libcudf reads it as `cudf::errc`, and a non-zero code fails the call with `CudfException: Transform UDF evaluation failed with error <CODE>`. It works through both the new and the old entry point. |
| Memory and streams | cuDF's default stream and current RMM memory resource, like every other cuDF call. |

**Tests** (in the patch, `java/src/test/java/ai/rapids/cudf/TransformMultiTest.java`, 35 tests,
run on a GPU by the JNI build's own test phase) cover:

* one, two and three inputs, mixed input types, and every tested output type;
* zero, one and a million rows;
* all-null, mixed-null and no-null inputs; functions that answer for a null, return a null for a
  non-null input, or unbox a null;
* error codes through both entry points;
* device memory accounted before and after successful and failing calls;
* argument validation.

## Pinned sources and applicability

| | Revision |
|---|---|
| NVIDIA `cudf-spark-jni` (renamed from `spark-rapids-jni`) | `761c184ff0a0dc5b678b1f5f163c579068beb133` |
| `rapidsai/cudf` (its submodule pin) | `ff5b362d7c06ae5837fd7a7337e2ae20895f324d` |

These are the revisions NVIDIA's released `com.nvidia:spark-rapids-jni:26.08.0:cuda12` records in
its own `spark-rapids-jni-version-info.properties` and `cudf-java-version-info.properties`. All
deeper dependencies are pinned by `thirdparty/cudf-pins/versions.json` inside that revision.

The patch applies to these revisions. **It has not been rebased onto, built against, or tested
with any newer cuDF or cudf-spark-jni release.** `ColumnViewJni.cpp` and `transform_extended`'s
signature may have moved since.

## Building

```bash
./build-cudf-spark-jni.sh /path/to/work/cudf-spark-jni
```

Requirements: Docker with `--gpus` support, network access, about 25 GB of disk (work tree, local Maven repository and NVIDIA's build image). No host CUDA
toolkit is needed. The script prints what it is about to build and refuses ambiguous settings.

| Variable | Default | Meaning |
|---|---|---|
| `CUDA_VERSION` | `12.9.1` | Toolkit of the build container; the Maven classifier follows its major (`cuda12`, `cuda13`; `-arm64` appended on aarch64). |
| `CMAKE_CUDA_ARCHITECTURES` | this machine's GPU | `89` builds SASS for 8.9 plus PTX; `RAPIDS` builds every architecture NVIDIA ships (hours); semicolon lists are refused. Building for a GPU the machine cannot run needs `ALLOW_ARCH_MISMATCH=1`. |
| `CPP_PARALLEL_LEVEL` | `8` | Parallel native compiles; each `nvcc` wants 2–3 GiB of RAM. |
| `JNI_VERSION` | `26.08.0-tcudf` | Version installed. Never NVIDIA's own, so the released artifact is not overwritten. |
| `LOCAL_MAVEN_REPO` | `~/.m2/repository` | Where `mvn install` puts the artifact (passed through `build-in-docker`). |
| `SKIP_BUILD=1` | | Prepare the tree and stop. |

The result is `com.nvidia:spark-rapids-jni:26.08.0-tcudf:<classifier>` in the local Maven
repository. To use it with Spark, fold it into the RAPIDS distribution with spark-jitudf's
`scripts/swap-cudf-jni.sh` rather than adding it to the class path. That script also verifies that
`transformMulti` links.

**Safety.** The work directory is a clone of NVIDIA's repository. On a rerun the helper restores
the cuDF submodule to its pin, but only after checking that every change in it is one the previous
build made: the patch files it applied, identified by content. It backs up what it removes and
refuses to touch anything else (an edited hunk, an unexpected file, a modified staged patch). It
never runs `git reset --hard`, `git clean` or a forced checkout.

## Verifying an installed JNI

```bash
# in spark-jitudf, after scripts/swap-cudf-jni.sh
VERIFY_ONLY=1 ./scripts/swap-cudf-jni.sh
```

Expect `JNI linkage: ... native methods resolve to exported functions, transformMulti among them`
and `verified: ...`. At run time RAPIDS logs `RAPIDS Accelerator JNI build: ... version -> 26.08.0-tcudf`.
