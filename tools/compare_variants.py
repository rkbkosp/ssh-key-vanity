#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Isolated M4 experiments; stdlib only. Run with uv run --no-project --python 3.12.

Never overwrites the normal binary, shader, or a pre-existing key. Generated
test private keys live in a private temporary directory and are removed after
OpenSSH readback and signature verification. Nonwinning seeds are never saved.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build" / "variant-experiments"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one source anchor: {old[:100]!r}")
    return text.replace(old, new, 1)


LOOKUP = r"""
// Experiment: fixed-address constant-table selection without a whole-point
// temporary. All eight entries are still read; no secret-dependent indexing.
static void cmov_constant(thread ge_precomp *t,
                          constant const ge_precomp *u, unsigned char b) {
    int mask = -int(b);
    for (int i = 0; i < 10; ++i) {
        t->yplusx[i] ^= mask & (t->yplusx[i] ^ u->yplusx[i]);
        t->yminusx[i] ^= mask & (t->yminusx[i] ^ u->yminusx[i]);
        t->xy2d[i] ^= mask & (t->xy2d[i] ^ u->xy2d[i]);
    }
}
static void select_base(thread ge_precomp *t, int pos, signed char b) {
    unsigned char neg = negative(b);
    unsigned char mag = b - (((-neg) & b) << 1);
    fe_1(t->yplusx); fe_1(t->yminusx); fe_0(t->xy2d);
    cmov_constant(t, &base[pos][0], equal(mag, 1));
    cmov_constant(t, &base[pos][1], equal(mag, 2));
    cmov_constant(t, &base[pos][2], equal(mag, 3));
    cmov_constant(t, &base[pos][3], equal(mag, 4));
    cmov_constant(t, &base[pos][4], equal(mag, 5));
    cmov_constant(t, &base[pos][5], equal(mag, 6));
    cmov_constant(t, &base[pos][6], equal(mag, 7));
    cmov_constant(t, &base[pos][7], equal(mag, 8));
    int mask = -int(neg);
    for (int i = 0; i < 10; ++i) {
        int a = t->yplusx[i], c = t->yminusx[i];
        t->yplusx[i] = a ^ (mask & (a ^ c));
        t->yminusx[i] = c ^ (mask & (a ^ c));
        int x = t->xy2d[i];
        t->xy2d[i] = x ^ (mask & (x ^ -x));
    }
}
"""

INVERT = r"""
    // One inversion per 64 candidates using a balanced product tree.
    // Full 64-lane groups are mandatory. No lane may return before barriers.
    threadgroup int tree[128][10];
    uint leaf = 64 + lane;
    for (uint k = 0; k < 10; ++k) tree[leaf][k] = point.Z[k];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    fe a, b, c, inv;
    for (uint width = 32; width != 0; width >>= 1) {
        if (lane < width) {
            uint node = width + lane;
            for (uint k = 0; k < 10; ++k) {
                a[k] = tree[2*node][k]; b[k] = tree[2*node+1][k];
            }
            fe_mul(c, a, b);
            for (uint k = 0; k < 10; ++k) tree[node][k] = c[k];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) {
        for (uint k = 0; k < 10; ++k) a[k] = tree[1][k];
        fe_invert(inv, a);
        for (uint k = 0; k < 10; ++k) tree[1][k] = inv[k];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint width = 1; width < 64; width <<= 1) {
        if (lane < width) {
            uint node = width + lane;
            for (uint k = 0; k < 10; ++k) {
                a[k] = tree[2*node][k]; b[k] = tree[2*node+1][k];
                inv[k] = tree[node][k];
            }
            fe_mul(c, inv, b);
            fe_mul(b, inv, a);
            for (uint k = 0; k < 10; ++k) {
                tree[2*node][k] = c[k]; tree[2*node+1][k] = b[k];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for (uint k = 0; k < 10; ++k) inv[k] = tree[leaf][k];
    fe_mul(a, point.X, inv); fe_mul(b, point.Y, inv);
    fe_tobytes(pub, b); pub[31] ^= fe_isnegative(a) << 7;
"""

PREFETCH = r"""
// Two protected staging buffers overlap system CSPRNG reads with SHA/GPU work.
// Candidate bytes are copied once then staging memory is cleared before reuse.
#include <thread>
#include <mutex>
#include <condition_variable>
class SeedPrefetch {
    Secret storage;
    size_t bytes, readIndex = 0, writeIndex = 0;
    bool ready[2] = {false, false}, stopping = false;
    std::mutex mutex;
    std::condition_variable changed;
    std::thread worker;
    void produce() {
        for (;;) {
            std::unique_lock<std::mutex> lock(mutex);
            changed.wait(lock, [&]{ return stopping || !ready[writeIndex]; });
            if (stopping) return;
            size_t index = writeIndex;
            lock.unlock();
            randombytes_buf(storage.p + index * bytes, bytes);
            lock.lock();
            if (stopping) return;
            ready[index] = true; writeIndex ^= 1;
            changed.notify_all();
        }
    }
public:
    explicit SeedPrefetch(size_t n) : storage(n * 2), bytes(n),
        worker([this]{ produce(); }) {}
    ~SeedPrefetch() {
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; }
        changed.notify_all(); worker.join();
    }
    void fill(unsigned char *out, size_t n) {
        require(n == bytes, "Prefetch batch size changed");
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&]{ return ready[readIndex]; });
        memcpy(out, storage.p + readIndex * bytes, bytes);
        sodium_memzero(storage.p + readIndex * bytes, bytes);
        ready[readIndex] = false; readIndex ^= 1;
        changed.notify_all();
    }
};
static std::unique_ptr<SeedPrefetch> seedPrefetch;
static void searchRandom(unsigned char *p, size_t n) {
    if (!seedPrefetch) seedPrefetch.reset(new SeedPrefetch(n));
    seedPrefetch->fill(p, n);
}
"""

HYBRID = r"""
#include <thread>
// Independent CPU candidates. The GPU and CPU share no candidate storage;
// only the main thread saves a winner, after joining the CPU workers.
class HybridCPU {
    Secret hitSeed{32};
    std::atomic<bool> stopping{false};
    std::atomic<unsigned> winnerState{0};
    std::atomic<uint64_t> completed{0};
    std::atomic<unsigned> observable{0};
    std::vector<std::thread> workers;
    std::string suffix;
    bool benchmark;
    bool isMatch(const unsigned char *pub) {
        for (size_t k = 0; k < suffix.size(); ++k) {
            size_t bit = (68 - suffix.size() + k) * 6;
            size_t byte = bit / 8 - 19;
            unsigned word = (unsigned)pub[byte] << 8;
            if (byte < 31) word |= pub[byte + 1];
            if (alphabet[(word >> (10 - bit % 8)) & 63] != suffix[k]) return false;
        }
        return true;
    }
    void work() {
        Secret seeds(256 * 32);
        unsigned char pub[32], secret[64];
        while (!stopping.load(std::memory_order_relaxed)) {
            randombytes_buf(seeds.p, seeds.n);
            uint64_t n = 0;
            unsigned checksum = 0;
            for (unsigned i = 0; i < 256; ++i) {
                if (stopping.load(std::memory_order_relaxed)) break;
                crypto_sign_seed_keypair(pub, secret, seeds.p + 32*i);
                sodium_memzero(secret, sizeof(secret));
                if (!benchmark && isMatch(pub)) {
                    unsigned expected = 0;
                    if (winnerState.compare_exchange_strong(expected, 1)) {
                        memcpy(hitSeed.p, seeds.p + 32*i, 32);
                        winnerState.store(2, std::memory_order_release);
                    }
                    stopping.store(true, std::memory_order_relaxed);
                    break;
                }
                ++n; checksum ^= unsigned(pub[0]);
            }
            completed.fetch_add(n, std::memory_order_relaxed);
            observable.fetch_xor(checksum, std::memory_order_relaxed);
            sodium_memzero(seeds.p, seeds.n);
        }
        sodium_memzero(secret, sizeof(secret));
    }
public:
    HybridCPU(unsigned count, const std::string &target, bool bench)
        : suffix(target), benchmark(bench) {
        try {
            for (unsigned i = 0; i < count; ++i) workers.emplace_back([this]{ work(); });
        } catch (...) { finish(); throw; }
    }
    ~HybridCPU() { finish(); }
    void finish() {
        stopping.store(true, std::memory_order_relaxed);
        for (auto &worker : workers) if (worker.joinable()) worker.join();
    }
    bool found() const { return winnerState.load(std::memory_order_acquire) == 2; }
    const unsigned char *seed() const { return hitSeed.p; }
    uint64_t count() const { return completed.load(std::memory_order_relaxed); }
};
"""


def make_variant(name, host, shader, vendor):
    folder = BASE / name
    (folder / "src").mkdir(parents=True, exist_ok=True)
    (folder / "vendor").mkdir(exist_ok=True)
    if "lookup" in name:
        start = vendor.index("static void select_base(")
        end = vendor.index("\n/*", start)
        vendor = vendor[:start] + LOOKUP + vendor[end:]
    if "invert" in name:
        shader = replace_once(shader, "uint tid [[thread_position_in_grid]])", "uint tid [[thread_position_in_grid]], uint lane [[thread_index_in_threadgroup]])")
        shader = replace_once(shader, "    if (mode == 0 && atomic_load_explicit(winner, memory_order_relaxed)) return;", "    // All lanes must participate in the inversion barriers.")
        shader = replace_once(shader, "    ge_p3_tobytes(pub, &point);", INVERT)
        host = replace_once(host, "        memset(winnerBuffer.contents, 0, 4);", '        require(threadgroup == 64 && count % 64 == 0, "Batch inversion requires full 64-lane groups");\n        memset(winnerBuffer.contents, 0, 4);')
    if "prefetch" in name:
        anchor = "static void put32(NSMutableData *out, uint32_t n) {"
        host = replace_once(host, anchor, PREFETCH + "\n" + anchor)
        host = replace_once(host, "        randombytes_buf(seeds.p, seeds.n);\n        deriveScalars(seeds.p,", "        searchRandom(seeds.p, seeds.n);\n        deriveScalars(seeds.p,")
        host = replace_once(host, "                    randombytes_buf(seeds.p, seeds.n);", "                    searchRandom(seeds.p, seeds.n);")
    hybrid_workers = 0
    if "hybrid" in name:
        hybrid_workers = int(name.rsplit("hybrid", 1)[1])
        if hybrid_workers not in (2, 4, 6, 8):
            raise RuntimeError("Hybrid experiment supports 2, 4, 6 or 8 CPU workers")
        anchor = "static void put32(NSMutableData *out, uint32_t n) {"
        host = replace_once(host, anchor, HYBRID + "\n" + anchor)
        host = replace_once(host, "\n    uint64_t total = 0; double start = now(), report = start;", f'\n    uint64_t total = 0; double start = now(), report = start;\n    HybridCPU hybrid({hybrid_workers}, suffix, benchmark > 0);\n    bool forceCPU = getenv("SSH_VANITY_TEST_CPU_WINNER") != nullptr;')
        host = replace_once(host, "                uint32_t winner = slot.finish();\n                if (winner) {", "                uint32_t winner = slot.finish();\n                if (winner && !forceCPU) {")
        host = replace_once(host, "                    saveKey(slot.seeds.p + (winner - 1) * 32, suffix, output);", '                    hybrid.finish();\n                    fprintf(stderr, "HYBRID gpu=%llu cpu=%llu winner=GPU\\n", (unsigned long long)total, (unsigned long long)hybrid.count());\n                    saveKey(slot.seeds.p + (winner - 1) * 32, suffix, output);')
        # Still one owner for saving files; a CPU winner uses the same verifier.
        anchor = "            double elapsed = now() - start;"
        host = replace_once(host, anchor, '''            if (!benchmark && hybrid.found()) {
                hybrid.finish();
                fprintf(stderr, "HYBRID gpu=%llu cpu=%llu winner=CPU\\n", (unsigned long long)total, (unsigned long long)hybrid.count());
                fprintf(stderr, "EXPERIMENT completed_nonmatching=%llu search_seconds=%.9f\\n", (unsigned long long)(total + hybrid.count()), now() - start);
                saveKey(hybrid.seed(), suffix, output);
                return 0;
            }
''' + anchor)
        host = replace_once(host, "                if (!pending) {\n                    elapsed = now() - start;", '                if (!pending) {\n                    hybrid.finish();\n                    fprintf(stderr, "HYBRID gpu=%llu cpu=%llu winner=none\\n", (unsigned long long)total, (unsigned long long)hybrid.count());\n                    total += hybrid.count();\n                    elapsed = now() - start;')
    # Common instrumentation counts only fully completed nonmatching batches.
    # The winning/in-flight partial batches are deliberately not counted.
    metric_count = "(total + hybrid.count())" if hybrid_workers else "total"
    host = replace_once(host, "                    saveKey(slot.seeds.p + (winner - 1) * 32, suffix, output);", f'                    fprintf(stderr, "EXPERIMENT completed_nonmatching=%llu search_seconds=%.9f\\n", (unsigned long long){metric_count}, now() - start);\n                    saveKey(slot.seeds.p + (winner - 1) * 32, suffix, output);')
    (folder / "src" / "vanity.mm").write_text(host)
    (folder / "src" / "search.metal").write_text(shader)
    (folder / "vendor" / "ed25519-ref10.metal").write_text(vendor)
    binary = folder / "ssh-vanity"
    subprocess.run(["xcrun", "clang++", "-O3", "-std=c++17", "-fobjc-arc", "-fblocks", "-Wno-deprecated-declarations", "-I/opt/homebrew/opt/libsodium/include", "-L/opt/homebrew/opt/libsodium/lib", "-lsodium", "-framework", "Foundation", "-framework", "Metal", str(folder / "src" / "vanity.mm"), "-o", str(binary)], check=True)
    return {"name": name, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "host_sha256": hashlib.sha256(host.encode()).hexdigest(), "shader_sha256": hashlib.sha256(shader.encode()).hexdigest(), "vendor_sha256": hashlib.sha256(vendor.encode()).hexdigest()}


def prepare(selected=None):
    host = (ROOT / "src" / "vanity.mm").read_text()
    shader = (ROOT / "src" / "search.metal").read_text()
    vendor = (ROOT / "vendor" / "ed25519-ref10.metal").read_text()
    variants = selected or ["baseline", "lookup", "invert", "prefetch"]
    manifest = {"created": time.strftime("%Y-%m-%d %H:%M:%S %z"), "python": sys.executable, "python_version": sys.version, "platform": platform.platform(), "variants": []}
    previous = BASE / "manifest.json"
    if previous.exists() and selected:
        manifest["variants"] = [v for v in json.loads(previous.read_text())["variants"] if v["name"] not in variants]
    for name in variants:
        manifest["variants"].append(make_variant(name, host, shader, vendor))
        print(f"Prepared {name}", flush=True)
    (BASE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


WATCHDOG = r"""
import os, signal, sys, time, pathlib, subprocess
target, supervisor, marker, identity = int(sys.argv[1]), int(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
while True:
    time.sleep(2)
    try:
        os.kill(supervisor, 0)
        if time.time() - marker.stat().st_mtime < 45:
            continue
    except (ProcessLookupError, FileNotFoundError):
        pass
    current = subprocess.run(['ps','-p',str(target),'-o','lstart='], capture_output=True,text=True).stdout.strip()
    if current == identity:
        os.kill(target, signal.SIGCONT)
        print('Watchdog resumed original search', flush=True)
    break
"""


def run_suite(args):
    manifest = json.loads((BASE / "manifest.json").read_text())
    names = args.variants.split(",") if args.variants else [v["name"] for v in manifest["variants"]]
    if not set(names).issubset(v["name"] for v in manifest["variants"]):
        raise RuntimeError("Requested variant has not been prepared")
    result_dir = ROOT / ".local" / ("compare-" + time.strftime("%Y%m%d-%H%M%S"))
    result_dir.mkdir(mode=0o700, parents=True)
    heartbeat = result_dir / "heartbeat"
    heartbeat.touch()
    identity = ""
    if args.pause_pid:
        identity = subprocess.check_output(["ps", "-p", str(args.pause_pid), "-o", "lstart="], text=True).strip()
        command = subprocess.check_output(["ps", "-p", str(args.pause_pid), "-o", "command="], text=True).strip()
        if "ssh-vanity" not in command or "--suffix 912778" not in command:
            raise RuntimeError("Refusing to suspend a process other than the requested 912778 search")
    watchdog_log = (result_dir / "watchdog.log").open("w")
    watchdog = subprocess.Popen([sys.executable, "-c", WATCHDOG, str(args.pause_pid), str(os.getpid()), str(heartbeat), identity], stdout=watchdog_log, stderr=subprocess.STDOUT, start_new_session=True) if args.pause_pid else None
    records = []
    paused = False

    def execute(argv, *, env=None, timeout=90):
        heartbeat.touch()
        start = time.perf_counter()
        with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env) as proc:
            try:
                while True:
                    try:
                        out, err = proc.communicate(timeout=1)
                        return proc.returncode, out, err, time.perf_counter() - start
                    except subprocess.TimeoutExpired:
                        heartbeat.touch()
                        if time.perf_counter() - start > timeout:
                            proc.send_signal(signal.SIGINT)
                            try:
                                proc.communicate(timeout=10)
                            except subprocess.TimeoutExpired:
                                proc.kill(); proc.communicate()
                            raise TimeoutError(f"Experiment timeout: {argv}")
            except BaseException:
                if proc.poll() is None:
                    proc.kill(); proc.communicate()
                raise

    def experiment(name, kind, round_number):
        folder = BASE / name
        binary = folder / "ssh-vanity"
        expected = next(v["binary_sha256"] for v in manifest["variants"] if v["name"] == name)
        if hashlib.sha256(binary.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Experimental executable changed since preparation")
        env = dict(os.environ, SSH_VANITY_ROOT=str(folder))
        target_suffix = "78" if kind == "cpu-validate" else "2778"
        if kind == "cpu-validate":
            env["SSH_VANITY_TEST_CPU_WINNER"] = "1"
        argv = [str(binary), "--backend", "metal", "--suffix", target_suffix, "--inflight", "2", "--batch", "16384", "--threadgroup", "64"]
        with tempfile.TemporaryDirectory(prefix="keys-", dir=result_dir) as keydir:
            key = Path(keydir) / "key"
            if kind == "validate":
                argv += ["--self-test"]
            elif kind == "throughput":
                argv += ["--benchmark", str(args.seconds)]
            else:
                argv += ["--max-seconds", "60", "--output", str(key)]
            code, out, err, wall = execute(argv, env=env)
            log_path = result_dir / f"{kind}-{round_number:02d}-{name}.log"
            log_path.write_text(err + out)
            record = {"kind": kind, "round": round_number, "variant": name, "exit_code": code, "wall_seconds": wall}
            if code != 0:
                raise RuntimeError(f"{name} {kind} failed ({code}); see {log_path}")
            if "Metal self-test passed" not in err:
                raise RuntimeError("Missing CPU/GPU validation")
            if kind == "throughput":
                matches = re.findall(r"(\d+) trials \| ([\d.]+) keys/s \| ([\d.]+)s \| all pending batches completed", err)
                if not matches:
                    raise RuntimeError("Missing throughput result")
                total, rate, seconds = matches[-1]
                record.update(completed_candidates=int(total), search_seconds=float(seconds), keys_per_second=float(rate))
            elif kind in ("search", "cpu-validate"):
                match = re.search(r"EXPERIMENT completed_nonmatching=(\d+) search_seconds=([\d.]+)", err)
                if not match or not key.exists():
                    raise RuntimeError("Missing actual search result")
                total, seconds = match.groups()
                derived_code, derived, derived_err, _ = execute(["ssh-keygen", "-y", "-f", str(key)])
                pub = key.with_suffix(".pub").read_text()
                if derived_code or derived.strip() != pub.strip() or not pub.split()[1].endswith(target_suffix) or key.stat().st_mode & 0o777 != 0o600:
                    raise RuntimeError(f"OpenSSH readback failed: {derived_err}")
                message = Path(keydir) / "message"
                message.write_text("Actual 2778 experiment signature validation\n")
                allowed = Path(keydir) / "allowed"
                allowed.write_text("experiment " + pub)
                sign_code, _, sign_err, _ = execute(["ssh-keygen", "-Y", "sign", "-f", str(key), "-n", "ssh-vanity-experiment", str(message)])
                with message.open() as message_input:
                    verified = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", "experiment", "-n", "ssh-vanity-experiment", "-s", str(message) + ".sig"], stdin=message_input, capture_output=True, text=True)
                if sign_code or verified.returncode:
                    raise RuntimeError("OpenSSH signature verification failed: " + sign_err + verified.stderr)
                record.update(completed_nonmatching=int(total), search_seconds=float(seconds), openssh_verified=True)
            hybrid_result = re.search(r"HYBRID gpu=(\d+) cpu=(\d+) winner=(\w+)", err)
            if hybrid_result:
                gpu_count, cpu_count, winner = hybrid_result.groups()
                record.update(gpu_candidates=int(gpu_count), cpu_candidates=int(cpu_count), winner=winner)
                if kind == "cpu-validate" and winner != "CPU":
                    raise RuntimeError("Forced CPU validation did not use a CPU winner")
            records.append(record)
            with (result_dir / "results.jsonl").open("a") as f:
                f.write(json.dumps(record) + "\n")
            print(json.dumps(record), flush=True)

    try:
        if args.pause_pid:
            os.kill(args.pause_pid, signal.SIGSTOP)
            paused = True
            print(f"Suspended {args.pause_pid}; watchdog active; results={result_dir}", flush=True)
        else:
            print(f"No existing search to suspend; results={result_dir}", flush=True)
        for name in names:
            experiment(name, "validate", 0)
            if "hybrid" in name:
                experiment(name, "cpu-validate", 0)
        # Alternate direction across rounds and bracket with baseline to detect drift.
        for round_number in range(args.throughput_rounds):
            order = names if round_number % 2 == 0 else list(reversed(names))
            for name in order:
                experiment(name, "throughput", round_number)
        for round_number in range(args.rounds):
            order = names[round_number % len(names):] + names[:round_number % len(names)]
            for name in order:
                experiment(name, "search", round_number)
        (result_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Completed: {result_dir}", flush=True)
    finally:
        if paused:
            current = subprocess.run(["ps", "-p", str(args.pause_pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
            if current == identity:
                os.kill(args.pause_pid, signal.SIGCONT)
                print(f"Resumed original PID {args.pause_pid}", flush=True)
        if watchdog:
            watchdog.terminate()
            watchdog.wait(timeout=5)
        watchdog_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--pause-pid", type=int)
    parser.add_argument("--run", action="store_true", help="Run without suspending another search")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--throughput-rounds", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--variants", help="Comma-separated isolated variants, e.g. baseline,invert-prefetch")
    args = parser.parse_args()
    print(f"Interpreter: {sys.executable}; {sys.version.split()[0]}", flush=True)
    if args.prepare:
        prepare(args.variants.split(",") if args.variants else None)
    if args.pause_pid or args.run:
        run_suite(args)
    elif not args.prepare:
        parser.error("Specify --prepare, --run or --pause-pid")


if __name__ == "__main__":
    main()
