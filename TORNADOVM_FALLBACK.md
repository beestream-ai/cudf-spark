# The `feature/tornadovm-udf-fallback` branch

This branch of a fork of [NVIDIA/cudf-spark](https://github.com/NVIDIA/cudf-spark) supports
**[beestream-ai/spark-jitudf](https://github.com/beestream-ai/spark-jitudf)**, which compiles
eligible numerical Spark Java UDFs on the driver with TornadoVM's TC compiler and runs them on the
GPU through cuDF's `transform`. Start there: its
[README](https://github.com/beestream-ai/spark-jitudf/blob/redesign/driver-side-tc-cudf/README.md)
and [INSTALL guide](https://github.com/beestream-ai/spark-jitudf/blob/redesign/driver-side-tc-cudf/docs/INSTALL.md)
build and use this branch. This file documents only what the branch changes.

## Base

Cut from NVIDIA's `release/26.08` at `1253310626da939c5924017d1c21e94d0932e0c1` ("Prepare
cudf-spark release v26.08.1-rc"), the revision the released `rapids-4-spark_2.13-26.08.1.jar`
records in its version-info. The independently validated revision of this branch is
`477c7dde10f88c3704414e2fe393dc2bcc702e1a` (tag `tc-cudf-review-20261125`).

`git diff 1253310626da939c5924017d1c21e94d0932e0c1 tc-cudf-review-20261125` shows every change:
17 files, all listed below.

## 1. Planner hook (`sql-plugin`, `udf-compiler`)

| File | Change |
|---|---|
| `udf-compiler/.../UdfCompileResult.scala` (new) | The RAPIDS UDF compiler reports **why** it declined a UDF (the unsupported construct), not only that it did. |
| `udf-compiler/.../LogicalPlanRules.scala`, `GpuScalaUDF.scala`, `CFG.scala`, `CatalystExpressionBuilder.scala`, `LambdaReflection.scala`, `Instruction.scala` (two shims) | Carry that reason through, so a later provider can decide whether it is worth trying. |
| `sql-plugin/.../TornadoUdfBridge.scala` (new) | Looks up the provider class named by `spark.rapids.sql.tornadovm.provider` (default `ai.beestream.jitudf.TornadoUdfProvider`) through the context class loader, calls its static `tryCompile(...)` reflectively with the UDF function object, input types, output type, nullability, determinism and the decline reasons, and returns the provider's `RapidsUDF` or `None`. Off unless `spark.rapids.sql.tornadovm.enabled=true`. Records each decision. |
| `sql-plugin/.../GpuScalaUDF.scala` (`GpuScalaUDFMeta`) | When a `ScalaUDF` has no hand-written `RapidsUDF`, asks the bridge during `tagExprForGpu`. A compiled UDF becomes `GpuScalaUDF` (`gpu_<name>`) around the provider's `RapidsUDF`; otherwise the expression keeps the RAPIDS behavior of the release. |

With `spark.rapids.sql.tornadovm.enabled=false` (the default) the branch behaves like the release.

### Original-receiver fallback (validated fix, 477c7dd)

RAPIDS' CPU bridge (`spark.rapids.sql.expression.cpuBridge.enabled`, default `true`) evaluates a
declined UDF through `BridgeHostColumnProjection`, which clones `ScalaUDF.function` on the worker by
**serializing it a second time** (`cloneFunction` → `Utils.clone`). For most UDFs that is harmless.
For a UDF whose deserialization is not idempotent, the result changes. Examples are a Java record
whose canonical constructor transforms a component, or a `readResolve` that rebuilds state.

The provider's `tryCompile` therefore takes a `Runnable requireOriginalReceiver` as an optional
last argument (the bridge falls back to the old signature if the provider lacks it). The provider
calls it when worker cloning cannot be proven to preserve the receiver. `GpuScalaUDFMeta` then
reports `isBridgeCompatible = false` and `preventsTreeBridgeOptimization = true` for that
expression, so the UDF is evaluated on the receiver Spark deserialized once:

* default settings: RAPIDS keeps that projection on Spark's CPU `Project` (any compiled sibling UDF
  in the same projection runs on the CPU too, with correct results);
* `spark.rapids.sql.rowBasedUDF.enabled=true`: the projection stays a `GpuProject`, the declined UDF
  runs as `gpu_row_based_<name>` and compiled siblings stay `gpu_<name>`.

The flag is set while the expression is tagged, before RAPIDS makes bridge decisions. With the
TornadoVM hook disabled, the stock bridge behavior applies unchanged.

## 2. Generalized cuDF `transform` JNI binding (`upstream-patches/`)

The released cuDF Java binding exposes `ColumnView.transform(String udf, boolean isPtx)`: one input
column, INT32 output, no null-awareness. libcudf's `cudf::transform_extended` already supports
multiple inputs, any fixed-width output type, null-aware execution and an error channel. The patch
widens the binding to reach them. It is a patch plus a build helper, not a change to this repository's
Scala code: [upstream-patches/README.md](upstream-patches/README.md).

`pom.xml` gains only a comment documenting `-Dspark-rapids-jni.version=26.08.0-tcudf`; the default
dependency stays NVIDIA's released `26.08.0`, so an ordinary build of this fork needs nothing built
locally.

## Building

`spark-jitudf`'s `scripts/build-rapids-patch.sh` builds this branch's `udf-compiler` and
`sql-plugin` for Spark 4.0.4 through the fork's own Maven reactor and replaces exactly the classes
compiled from the changed sources in `spark404/` and `spark-shared/` of NVIDIA's released 26.08.1
jar. A full distribution build of all 25 Spark shims is not needed for Spark 4.0.4.

## Licence

Everything on this branch stays under the RAPIDS project's Apache License 2.0, with its file
headers and `NOTICE` intact. New Scala files use the repository's standard Apache 2.0 file header,
as its copyright check expects. The scripts in `upstream-patches/` carry a Beestream Ltd Apache 2.0
header.
