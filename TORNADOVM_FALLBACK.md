# The `feature/tornadovm-udf-fallback` branch

This branch exists to support **[beestream-ai/spark-jitudf](https://github.com/beestream-ai/spark-jitudf)**,
which compiles a Spark JVM UDF into a GPU kernel with TornadoVM and runs it over the cuDF column
buffers in place.

If you are looking at this branch on its own, you probably want that repository first: it has the
build instructions, the evaluation and the reproduction guide. This branch is a dependency of it,
not a standalone thing.

## What it changes

Ten files in `udf-compiler` and `sql-plugin`, about 380 lines, cut from `release/26.08` at the
`v26.08.1-rc` commit.

The RAPIDS `udf-compiler` translates a JVM UDF into Catalyst expressions. An expression tree cannot
hold a loop, so a UDF containing one is declined and the batch crosses to the CPU row by row.
Before this branch, the decline was reported only as a failure to translate. After it:

| | |
|---|---|
| `UdfCompileResult` | The compiler says **why** it declined — the specific unsupported construct — instead of only that it did. |
| `TornadoUdfBridge` | Looks up a provider that may be able to compile what the expression builder could not, and hands it the UDF. Off unless `spark.rapids.sql.tornadovm.enabled=true`. |
| `LogicalPlanRules`, `GpuScalaUDF` | Let that second attempt happen during planning, so a UDF that cannot be compiled keeps exactly the path it already had. |

The provider class is named by `spark.rapids.sql.tornadovm.provider`, defaulting to
`ai.beestream.jitudf.TornadoUdfProvider`. Nothing changes until the config is set: with the
feature off, this branch behaves as the release it was cut from.

## Building it

`scripts/build-rapids-patch.sh` in spark-jitudf builds the changed sources through this project's
own reactor and replaces exactly those classes in the released distribution jar. See
[REPRODUCING.md](https://github.com/beestream-ai/spark-jitudf/blob/main/REPRODUCING.md) there.

## Relationship to upstream

A fork of [NVIDIA/cudf-spark](https://github.com/NVIDIA/cudf-spark), kept so the branch is
cloneable. Everything on it stays under the RAPIDS project's Apache 2.0 licence with its file
headers intact; new files follow the same convention as their neighbours.
