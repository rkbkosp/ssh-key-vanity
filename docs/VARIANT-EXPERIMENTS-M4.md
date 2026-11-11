# Apple M4 algorithm and pipeline experiments, 2026-11-10

These are isolated experiments, not a change to the normal executable. The first
two suites suspend and restore the original `912778` search, with a separate
resume watchdog and a `finally` resume path. The user then killed the old search;
CPU/GPU hybrid suites run without an existing search. Source snapshots and
experimental executables are under
`build/variant-experiments/`; local execution logs are under `.local/compare-*`.

## Variants

- **baseline:** current Objective-C++ / Metal implementation, batch 16,384,
  threadgroup 64, two in-flight batches. The only common instrumentation added
  is a counter logged immediately before saving a winning key.
- **lookup:** replace the temporary point copies in fixed-base table selection
  with direct conditional moves from the constant address space. Every one of
  the eight entries is still accessed; no secret-indexed table access is added.
- **invert:** retain independent seed hashing and full fixed-base multiplication
  for every candidate, but share one field inversion among 64 lanes. A balanced
  product tree computes all 64 reciprocal Z coordinates using one inversion and
  189 multiplications, with threadgroup barriers. Public-key encoding and suffix
  matching then proceed normally. This experimental implementation requires full
  64-lane threadgroups and a batch size divisible by 64.
- **prefetch:** a producer thread fills two protected staging buffers with the
  same libsodium system CSPRNG. The consumer copies one batch, clears its staging
  storage, and releases the buffer. This overlaps random-byte reads with hashing
  and GPU work, at the cost of approximately 1 MiB of extra protected storage and
  another memory copy. It does not substitute a weak PRNG or persist seeds.
- **invert-prefetch:** combine the latter two changes to check whether the faster
  GPU starts to benefit from independent random-byte preparation.
- **invert-hybrid2 / invert-hybrid4 / invert-hybrid6 / invert-hybrid8:** add
  two, four, six or eight CPU worker threads doing
  full libsodium Ed25519 seed-to-key generation concurrently with the inversion
  GPU kernel. Each worker owns independent protected seed storage. Workers
  publish a winning seed through an atomic state; only the main thread verifies
  and saves a key, after joining all CPU workers. Thread counts are scheduling
  requests, not physical-core affinity. GPU and CPU completed candidates are
  reported separately, then summed for total throughput.

## Method

Environment: local Apple M4, 10-core GPU, macOS 27.2, libsodium 1.0.22. Host
sources use `clang++ -O3 -std=c++17`; Metal uses the normal runtime compiler.
Each variant is prepared from a frozen copy of the same normal source. Manifests
record SHA-256 values for all generated host/shader/vendor sources and binaries.
The Python helper uses only the standard library and is run with uv-managed
Python 3.12.16; it does not change project dependency formats or the system Python.

There are two complementary measurements:

1. **Fixed-duration throughput:** includes system random-byte generation,
   SHA-512/clamping, GPU computation, host dispatch/handling and draining pending
   batches. Runtime compilation and startup self-tests are excluded from the
   reported search rate. Full public keys are written to an observable RAM buffer
   for every candidate. This prevents deletion of unused computations, but is
   slightly different from a search that writes only the winning index.
2. **Actual `2778` end-to-end searches:** measure subprocess launch through exit,
   including library setup, cached Metal compilation, startup self-tests, secure
   candidate generation, real matching, independent CPU validation, key writing,
   GPU draining and teardown. Additional external OpenSSH verification is outside
   this measured interval. Compilation of the host executable is excluded.

An initial validation pass warms the Metal cache before timed comparisons, so
the reported launch timings are not cold-cache compilation measurements.
Variants run sequentially, with order rotated/reversed between rounds. No second
search or benchmark competes with the experiment for this GPU.

The first suite uses three 5-second throughput rounds and eight independent
actual searches per variant. The follow-up compares baseline, inversion and
inversion plus prefetch with three 8-second throughput rounds and four actual
searches each.

All search processes generate genuinely fresh random candidates; they do not
replay the same candidate stream. Therefore, raw time to a random hit is not
a fair speed ranking. The actual-search rate below divides the sum of fully
completed nonmatching candidates by the sum of measured launch-to-exit times.
It deliberately omits the winning and remaining in-flight GPU batches, making it
a conservative rate. At most two GPU batches (32,768 candidates) and any
simultaneous CPU-winning candidates per hit are omitted.
Short lucky searches also pay proportionally more startup overhead.

## Validation

Every invocation compares 1,024 GPU public keys with libsodium and exercises the
real matching path for suffix lengths 1 through 8. Every successful actual search
is also checked for a `2778` public-key suffix, private-file mode `0600`, identical
public-key derivation with `ssh-keygen -y`, and an OpenSSH signature/verification
round trip. Temporary private keys and their temporary directory are deleted
after these checks. Nonwinning candidate seeds are never logged or written to
disk. Winning seeds exist only in the temporary test private keys during checks.

The hybrid variants additionally run one forced CPU-winner `78` test each:
GPU results are ignored for this validation only, so the CPU winner's publication,
shutdown and save path must succeed and pass OpenSSH checks. These forced runs
are excluded from all performance summaries. Timed hybrid searches use the real
`2778` target and accept a winner from either processor.

## Results

**Recommendation: batch inversion plus four CPU worker threads.** In the final
sweep it reached a median 3.818 million keys/s, versus 3.789 million with six
threads and 3.529 million with eight. Six threads did not establish a throughput
advantage; four used fewer CPU workers. Compared with the normal implementation's
approximately 3.0 million keys/s, the combined result is about 26-29% higher in
these short local measurements. This is not a sustained-performance guarantee.

On 2026-11-11 the user reported that whole-machine power draw during actual use
of the recommended configuration could approach full load. Keep the machine
well ventilated and allow adequate cooling during long searches. This is a
user-observed power result, separate from the throughput suites below; no wattage
or temperature measurement is recorded in these benchmark files.

The isolated lookup change did not improve performance. System-random prefetch
did not establish a repeatable improvement and added no benefit to inversion.
Batch inversion alone improved fixed-duration throughput by about 19-21% and
actual end-to-end throughput by about 18-21% in the first two suites.

CPU/GPU overlap was measured, rather than estimated by adding standalone rates.
In suite 3 the medians were 3.468 million keys/s for inversion GPU alone,
3.628 million with two CPU workers and 3.758 million with four. In suite 4,
eight CPU workers produced more CPU candidates, but fewer GPU candidates and
lower combined throughput than four workers. These data do not isolate whether
CPU scheduling, power sharing or another device effect caused that decrease.

The tables show median fixed-duration throughput, followed by a conservative
actual-search rate including startup and output. **Raw average hit time is
included for inspection, not speed ranking:** candidate counts differ because
all searches use fresh randomness. For example, suite 1 inversion had a longer
mean hit time than baseline while processing substantially more candidates per
second.

### Suite 1

| Variant | Median throughput, M keys/s | Actual end-to-end rate, M keys/s | Actual hits | Mean raw hit time, s |
| --- | ---: | ---: | ---: | ---: |
| baseline | 2.967 | 2.860 | 8 | 4.918 |
| lookup | 2.932 | 2.777 | 8 | 3.399 |
| invert | 3.578 | 3.388 | 8 | 5.596 |
| prefetch | 2.956 | 2.934 | 8 | 8.389 |

### Suite 2

| Variant | Median throughput, M keys/s | Actual end-to-end rate, M keys/s | Actual hits | Mean raw hit time, s |
| --- | ---: | ---: | ---: | ---: |
| baseline | 3.030 | 2.798 | 4 | 4.428 |
| invert | 3.605 | 3.386 | 4 | 3.552 |
| invert-prefetch | 3.554 | 3.399 | 4 | 3.605 |

### Suite 3

| Variant | Median throughput, M keys/s | Actual end-to-end rate, M keys/s | Actual hits | Mean raw hit time, s |
| --- | ---: | ---: | ---: | ---: |
| invert | 3.468 | 3.407 | 4 | 8.074 |
| invert-hybrid2 | 3.628 | 3.449 | 4 | 2.231 |
| invert-hybrid4 | 3.758 | 3.656 | 4 | 3.042 |

### Suite 4

| Variant | Median throughput, M keys/s | Actual end-to-end rate, M keys/s | Actual hits | Mean raw hit time, s |
| --- | ---: | ---: | ---: | ---: |
| invert-hybrid4 | 3.818 | 3.772 | 4 | 2.971 |
| invert-hybrid6 | 3.789 | 3.822 | 4 | 4.945 |
| invert-hybrid8 | 3.529 | 3.575 | 4 | 4.293 |

All **68 actual `2778` searches and five forced CPU-winner short-suffix checks**
passed independent OpenSSH readback, file-mode and signature checks. One of the
actual `2778` hybrid searches was won by the CPU. No temporary test private-key
directories remain. SHA-256 checks confirm the normal host source, normal shader,
vendor source and `build/ssh-vanity` are unchanged.

Raw machine-readable records, including source/binary hashes, are in
[variant-results-m4.jsonl](variant-results-m4.jsonl). Local per-invocation logs are
in the four `.local/compare-20261110-*` directories represented by the suite
numbers. All experimental binaries remain separate under
`build/variant-experiments/`.

The original search was restored after each initial suite. The user explicitly
killed it before the hybrid tests; it remains stopped and no new `912778` search
was started. These results recommend an experimental configuration; they do not
claim that the normal executable has adopted these changes.


## Reproduce

To run the recommended experimental configuration after preparation, explicitly
opt in to its separate executable (the normal `run.sh` is unchanged):

```sh
SSH_VANITY_ROOT="$PWD/build/variant-experiments/invert-hybrid4" \
  ./build/variant-experiments/invert-hybrid4/ssh-vanity \
  --backend metal --suffix 912778 --output ./912778_key \
  --batch 16384 --threadgroup 64 --inflight 2
```

Run one suite at a time. Use the PID of the specific existing `912778` search;
the helper checks the command and process launch time before suspending/resuming.

```sh
uv run --no-project --python 3.12 tools/compare_variants.py --prepare
uv run --no-project --python 3.12 tools/compare_variants.py \
  --pause-pid PID --rounds 8 --throughput-rounds 3 --seconds 5

uv run --no-project --python 3.12 tools/compare_variants.py \
  --prepare --variants invert-prefetch
uv run --no-project --python 3.12 tools/compare_variants.py \
  --pause-pid PID --variants baseline,invert,invert-prefetch \
  --rounds 4 --throughput-rounds 3 --seconds 8

# With no other search running:
uv run --no-project --python 3.12 tools/compare_variants.py \
  --prepare --variants invert-hybrid2,invert-hybrid4
uv run --no-project --python 3.12 tools/compare_variants.py \
  --run --variants invert,invert-hybrid2,invert-hybrid4 \
  --rounds 4 --throughput-rounds 3 --seconds 8

uv run --no-project --python 3.12 tools/compare_variants.py \
  --prepare --variants invert-hybrid6,invert-hybrid8
uv run --no-project --python 3.12 tools/compare_variants.py \
  --run --variants invert-hybrid4,invert-hybrid6,invert-hybrid8 \
  --rounds 4 --throughput-rounds 3 --seconds 8
```

Suspension does not reset or discard the original process's candidate state.
Its existing elapsed-time counter uses wall time, however, so its cumulative
displayed `keys/s` includes the pause and temporarily understates its active
search rate after resumption. This is a limitation of the original reporting.
