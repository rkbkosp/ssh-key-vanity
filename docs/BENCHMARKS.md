# Apple M4 performance notes

**Optimized and benchmarked only for Apple M4 (10-core GPU).** Other Apple
Silicon models, including M4 Pro/Max, are unverified. These are short local
measurements, not sustained-performance guarantees or comparisons with other
implementations.

Environment: macOS 27.2, Apple M4, 10 CPU cores, 10 GPU cores, 16 GiB unified
memory. Measurements were collected on 2026-11-10. Runtime compilation and
startup validation are excluded; secure random seed generation, CPU SHA-512,
GPU dispatch and result handling are included.

| Backend / configuration | Measurement | Throughput |
| --- | --- | ---: |
| CPU, 8 workers | Initial independent 5 s run | 493,357 keys/s |
| Metal, batch 16,384, group 64, inflight 1 | Initial independent 5 s run | 1,293,660 keys/s |
| Metal, batch 16,384, group 64, inflight 1 | Later isolated 4 s run | 1,312,541 keys/s |
| Metal, batch 16,384, group 64, inflight 2 | Later isolated 4 s run | 2,967,943 keys/s |
| Metal, batch 16,384, group 64, inflight 3 | Later isolated 4 s run | 3,009,569 keys/s |
| Metal, batch 16,384, group 64, inflight 2, actual search | 12,042,240 completed candidates in 4.01 s | 3,006,651 keys/s |

The later measurements briefly suspended the existing search to prevent
competition, and automatically resumed it afterwards. Actual search used
suffix `912778`; no match was found or key file written during that run.
Benchmark mode always writes public results to a RAM buffer so the compiler
cannot remove unused key-generation work.

Two pending batches improved throughput by about 2.26x in this implementation.
Three pending batches added little. Increasing a synchronous batch to 65,536
reached about 1.99 million keys/s in the focused sweep. The grouped sweep and
repeat baseline also show clock/scheduling variability; no single row should
be treated as a fixed ceiling.

Raw, non-sensitive sweep data:

- [Initial short sweep](tuning-m4.csv): approximately 0.4 s per configuration.
- [Focused sweep](tuning-focused-m4.csv): approximately 1.5 s per configuration.

## Observed bottleneck

In a 3 s sample of the original synchronous search's main thread, approximately
87% of samples were in `waitUntilCompleted`, 10% reading secure random bytes,
and 2.4% preparing SHA-512 scalars. This identifies a host-side submission and
overlap opportunity; it does not identify GPU instruction or bandwidth limits.
Each pending batch owns separate buffers, allowing CPU preparation and multiple
GPU command buffers to overlap safely.

One system-wide GPU utilization reading was 84%, including unrelated apps.
Root-only power/thermal and detailed GPU occupancy/register/bandwidth counters
were not collected. Consequently, there is no claim that the remaining limit
is register pressure, memory bandwidth, or a measured hardware maximum.

CSV `gpu_ms` sums each completed command buffer's `GPUEndTime-GPUStartTime`.
Intervals may overlap, so their sum can exceed wall time and is **not** a GPU
utilization percentage. See [Apple's timestamp documentation](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime).

## Reproduce

Run one workload at a time. Benchmarking does not write key files:

```sh
./run.sh --backend metal --suffix 912778 --benchmark 10 --inflight 1
./run.sh --backend metal --suffix 912778 --benchmark 10 --inflight 2
./run.sh --backend cpu --suffix 912778 --benchmark 10
./scripts/profile.sh --focused > tuning.csv
```

The profiler validates 1,024 GPU results against libsodium for each tested
threadgroup size before the sweep. `--pause-pid PID` is an explicit opt-in
that sends SIGSTOP to that PID during the sweep, followed by SIGCONT, with a
30 s resume watchdog. It is not used by default. Do not point it at unrelated
processes.

## Probability

For an `n`-character Base64 suffix, approximately `64^n` trials are needed on
average. At 2.97 million keys/s:

| Suffix length | Expected trials | Mean wait | Approximate 95% wait |
| --- | ---: | ---: | ---: |
| 4 | 16,777,216 | 5.6 s | 16.9 s |
| 6 | 68,719,476,736 | 6.4 h | 19.3 h |
| 8 | 281,474,976,710,656 | 3.0 years | 9.0 years |

The 95% time is about three times the mean; neither is a completion deadline.
