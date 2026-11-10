// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rkbkosp
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <sodium.h>
#include <atomic>
#include <arpa/inet.h>
#include <chrono>
#include <cmath>
#include <csignal>
#include <fcntl.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static volatile sig_atomic_t stopped = 0;
static void stopHandler(int) { stopped = 1; }
static const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static double now() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
// sodium_malloc: locked, guarded memory; no candidate key files are created.
struct Secret {
    unsigned char *p; size_t n;
    explicit Secret(size_t size) : p((unsigned char *)sodium_malloc(size)), n(size) {
        require(p != nullptr, "Cannot allocate private memory");
    }
    ~Secret() { sodium_free(p); }
    Secret(const Secret &) = delete;
};
static void put32(NSMutableData *out, uint32_t n) {
    n = htonl(n); [out appendBytes:&n length:4];
}
static void putString(NSMutableData *out, NSData *value) {
    put32(out, (uint32_t)value.length); [out appendData:value];
}
static NSData *bytes(const void *p, size_t n) { return [NSData dataWithBytes:p length:n]; }
static NSData *textData(const char *s) { return bytes(s, strlen(s)); }
static NSMutableData *publicBlob(const unsigned char *pub) {
    NSMutableData *blob = [NSMutableData data];
    putString(blob, textData("ssh-ed25519")); putString(blob, bytes(pub, 32));
    return blob;
}
static bool matches(const unsigned char *pub, const std::string &suffix) {
    // Independent CPU check using Foundation's actual Base64 encoder.
    NSString *encoded = [publicBlob(pub) base64EncodedStringWithOptions:0];
    return [encoded hasSuffix:[NSString stringWithUTF8String:suffix.c_str()]];
}
static void deriveScalars(const unsigned char *seeds, unsigned char *scalars, uint32_t count) {
    dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
        unsigned char hash[64];
        for (size_t i = worker; i < count; i += 8) {
            crypto_hash_sha512(hash, seeds + i * 32, 32);
            hash[0] &= 248; hash[31] &= 63; hash[31] |= 64;
            memcpy(scalars + i * 32, hash, 32);
        }
        sodium_memzero(hash, sizeof(hash));
    });
}
struct GPU {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline;
    id<MTLBuffer> scalars, winner, verification;
    size_t capacity;
    NSUInteger threadgroup = 64;
    explicit GPU(size_t count, NSString *root) : capacity(count) {
        device = MTLCreateSystemDefaultDevice();
        require(device != nil, "No Metal GPU; use --backend cpu");
        NSError *error = nil;
        NSString *base = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"vendor/ed25519-ref10.metal"] encoding:NSUTF8StringEncoding error:&error];
        if (!base) throw std::runtime_error(error.localizedDescription.UTF8String);
        NSString *search = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"src/search.metal"] encoding:NSUTF8StringEncoding error:&error];
        if (!search) throw std::runtime_error(error.localizedDescription.UTF8String);
        fprintf(stderr, "Loading Metal shader (runtime compiler; first use may take a moment)…\n");
        id<MTLLibrary> library = [device newLibraryWithSource:[base stringByAppendingString:search] options:nil error:&error];
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
        pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"ssh_vanity"] error:&error];
        if (!pipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
        queue = [device newCommandQueue];
        scalars = [device newBufferWithLength:count * 32 options:MTLResourceStorageModeShared];
        winner = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        verification = [device newBufferWithLength:count * 32 options:MTLResourceStorageModeShared];
        require(queue && scalars && winner && verification, "Metal buffer allocation failed");
    }
    ~GPU() {
        if (scalars) sodium_memzero(scalars.contents, scalars.length);
        if (winner) sodium_memzero(winner.contents, winner.length);
    }
    uint32_t run(const unsigned char *seeds, uint32_t count, const std::string &suffix, uint32_t mode) {
        deriveScalars(seeds, (unsigned char *)scalars.contents, count);
        id<MTLCommandBuffer> command = launch(count, suffix, mode, scalars, winner, verification);
        [command waitUntilCompleted];
        sodium_memzero(scalars.contents, count * 32);
        if (command.status != MTLCommandBufferStatusCompleted)
            throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "Metal execution failed");
        return *(uint32_t *)winner.contents;
    }
    id<MTLCommandBuffer> launch(uint32_t count, const std::string &suffix, uint32_t mode,
                               id<MTLBuffer> scalarBuffer, id<MTLBuffer> winnerBuffer,
                               id<MTLBuffer> outputBuffer) {
        memset(winnerBuffer.contents, 0, 4);
        unsigned char target[8] = {};
        for (size_t i = 0; i < suffix.size(); ++i) target[i] = strchr(alphabet, suffix[i]) - alphabet;
        uint32_t length = (uint32_t)suffix.size();
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:scalarBuffer offset:0 atIndex:0];
        [encoder setBuffer:winnerBuffer offset:0 atIndex:1];
        [encoder setBytes:target length:8 atIndex:2];
        [encoder setBytes:&length length:4 atIndex:3];
        [encoder setBytes:&count length:4 atIndex:4];
        [encoder setBytes:&mode length:4 atIndex:5];
        [encoder setBuffer:outputBuffer offset:0 atIndex:6];
        NSUInteger group = MIN(threadgroup, pipeline.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
        [encoder endEncoding]; [command commit];
        return command;
    }
    void selfTest() {
        const uint32_t count = 1024;
        Secret seeds(count * 32); randombytes_buf(seeds.p, seeds.n);
        // RFC 8032 test 1 seed. The other 1023 seeds exercise random inputs.
        sodium_hex2bin(seeds.p, 32,
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", 64, nullptr, nullptr, nullptr);
        run(seeds.p, count, "2778", 2);
        unsigned char pub[32], sk[64];
        for (uint32_t i = 0; i < count; ++i) {
            crypto_sign_seed_keypair(pub, sk, seeds.p + i * 32);
            sodium_memzero(sk, sizeof(sk));
            require(memcmp(pub, (unsigned char *)verification.contents + i * 32, 32) == 0,
                    "GPU self-test failed: public key differs from libsodium");
        }
        // Also test the real matcher/atomic path for every supported suffix length.
        uint32_t last = (uint32_t)capacity - 1;
        for (size_t n = 1; n <= 8; ++n) {
            // Pin a known matching candidate to the final GPU lane.
            Secret batch(capacity * 32); randombytes_buf(batch.p, batch.n);
            memcpy(batch.p + last * 32, seeds.p, 32);
            crypto_sign_seed_keypair(pub, sk, seeds.p); sodium_memzero(sk, sizeof(sk));
            NSString *b64 = [publicBlob(pub) base64EncodedStringWithOptions:0];
            std::string suffix([[b64 substringFromIndex:b64.length - n] UTF8String]);
            uint32_t found = run(batch.p, (uint32_t)capacity, suffix, 0);
            require(found > 0 && found <= capacity, "GPU suffix test failed: no hit");
            crypto_sign_seed_keypair(pub, sk, batch.p + (found - 1) * 32);
            sodium_memzero(sk, sizeof(sk));
            require(matches(pub, suffix), "GPU suffix test failed: wrong hit");
        }
        fprintf(stderr, "Metal self-test passed: 1024 CPU/GPU comparisons and suffix lengths 1..8.\n");
    }
};
static uint32_t cpuBatch(const unsigned char *seeds, uint32_t count,
                         const std::string &suffix, bool benchmark) {
    std::atomic<uint32_t> result(0);
    std::atomic<uint32_t> *winner = &result;
    dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
        @autoreleasepool {
            unsigned char pub[32], sk[64];
            for (size_t i = worker; i < count; i += 8) {
                if (stopped || (!benchmark && winner->load(std::memory_order_relaxed))) break;
                crypto_sign_seed_keypair(pub, sk, seeds + i * 32);
                sodium_memzero(sk, sizeof(sk));
                bool hit = true;
                for (size_t k = 0; k < suffix.size(); ++k) {
                    size_t bit = (68 - suffix.size() + k) * 6;
                    size_t byte = bit / 8 - 19;
                    unsigned word = (unsigned)pub[byte] << 8;
                    if (byte < 31) word |= pub[byte + 1];
                    if (alphabet[(word >> (10 - bit % 8)) & 63] != suffix[k]) hit = false;
                }
                if (!benchmark && hit) {
                    uint32_t expected = 0;
                    winner->compare_exchange_strong(expected, (uint32_t)i + 1);
                }
            }
        }
    });
    return result.load();
}
static void writeExclusive(const std::string &path, const void *p, size_t n, mode_t mode) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode);
    if (fd < 0) throw std::runtime_error("Cannot exclusively create " + path + ": " + strerror(errno));
    size_t offset = 0;
    while (offset < n) {
        ssize_t written = write(fd, (const char *)p + offset, n - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { close(fd); unlink(path.c_str()); throw std::runtime_error("Key write failed"); }
        offset += (size_t)written;
    }
    bool ok = fsync(fd) == 0; int closeResult = close(fd);
    if (!ok || closeResult != 0) { unlink(path.c_str()); throw std::runtime_error("Key flush failed"); }
}
static void saveKey(const unsigned char *seed, const std::string &suffix, const std::string &path) {
    unsigned char pub[32]; Secret sk(64);
    crypto_sign_seed_keypair(pub, sk.p, seed);
    require(matches(pub, suffix), "Refusing to save: CPU verification did not match suffix");
    // Sign and verify before serializing; only the matching seed reaches disk.
    unsigned char signature[64]; const unsigned char message[] = "ssh-vanity-key-check";
    crypto_sign_detached(signature, nullptr, message, sizeof(message), sk.p);
    require(crypto_sign_verify_detached(signature, message, sizeof(message), pub) == 0, "Signature self-check failed");
    NSMutableData *pubBlob = publicBlob(pub);
    NSMutableData *inner = [NSMutableData data];
    uint32_t check; randombytes_buf(&check, sizeof(check)); put32(inner, check); put32(inner, check);
    putString(inner, textData("ssh-ed25519")); putString(inner, bytes(pub, 32));
    putString(inner, bytes(sk.p, 64)); putString(inner, textData(""));
    for (uint8_t pad = 1; inner.length % 8 != 0; ++pad) [inner appendBytes:&pad length:1];
    NSMutableData *outer = [NSMutableData dataWithBytes:"openssh-key-v1\0" length:15];
    putString(outer, textData("none")); putString(outer, textData("none"));
    putString(outer, textData("")); put32(outer, 1); putString(outer, pubBlob); putString(outer, inner);
    NSString *encoded = [outer base64EncodedStringWithOptions:0];
    NSMutableString *pem = [NSMutableString stringWithString:@"-----BEGIN OPENSSH PRIVATE KEY-----\n"];
    for (NSUInteger i = 0; i < encoded.length; i += 70)
        [pem appendFormat:@"%@\n", [encoded substringWithRange:NSMakeRange(i, MIN((NSUInteger)70, encoded.length - i))]];
    [pem appendString:@"-----END OPENSSH PRIVATE KEY-----\n"];
    NSString *publicLine = [NSString stringWithFormat:@"ssh-ed25519 %@\n", [pubBlob base64EncodedStringWithOptions:0]];
    NSData *privateData = [pem dataUsingEncoding:NSASCIIStringEncoding];
    NSData *publicData = [publicLine dataUsingEncoding:NSASCIIStringEncoding];
    // Reserve .pub first, so an existing path never causes private-key overwrite.
    writeExclusive(path + ".pub", publicData.bytes, publicData.length, 0644);
    try { writeExclusive(path, privateData.bytes, privateData.length, 0600); }
    catch (...) { unlink((path + ".pub").c_str()); throw; }
    sodium_memzero(inner.mutableBytes, inner.length); sodium_memzero(outer.mutableBytes, outer.length);
    fprintf(stderr, "Found and CPU-verified. Private key: %s\nPublic key: %s.pub\n", path.c_str(), path.c_str());
    printf("%s", publicLine.UTF8String);
}
// Each pending batch owns its seeds and GPU buffers until completion. The CPU
// can prepare another batch without changing any memory the GPU is reading.
struct PendingBatch {
    Secret seeds;
    id<MTLBuffer> scalars, winner, publicKeys;
    id<MTLCommandBuffer> command;
    PendingBatch(GPU &gpu, uint32_t count) : seeds((size_t)count * 32) {
        scalars = [gpu.device newBufferWithLength:seeds.n options:MTLResourceStorageModeShared];
        winner = [gpu.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        publicKeys = [gpu.device newBufferWithLength:seeds.n options:MTLResourceStorageModeShared];
        require(scalars && winner && publicKeys, "Pending batch allocation failed");
    }
    ~PendingBatch() {
        if (command) [command waitUntilCompleted];
        if (scalars) sodium_memzero(scalars.contents, scalars.length);
        if (winner) sodium_memzero(winner.contents, winner.length);
    }
    void submit(GPU &gpu, uint32_t count, const std::string &suffix, bool benchmark) {
        require(command == nil, "Refusing to reuse a pending GPU buffer");
        randombytes_buf(seeds.p, seeds.n);
        deriveScalars(seeds.p, (unsigned char *)scalars.contents, count);
        command = gpu.launch(count, suffix, benchmark ? 1 : 0, scalars, winner, publicKeys);
    }
    uint32_t finish() {
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "Metal execution failed");
        uint32_t result = *(uint32_t *)winner.contents;
        sodium_memzero(scalars.contents, scalars.length);
        command = nil;
        return result;
    }
};
static int pipelinedSearch(GPU &gpu, uint32_t batch, uint32_t depth,
                          const std::string &suffix, const std::string &output,
                          double benchmark, double maxSeconds) {
    std::vector<std::unique_ptr<PendingBatch>> slots;
    for (uint32_t i = 0; i < depth; ++i) slots.emplace_back(new PendingBatch(gpu, batch));
    uint64_t total = 0; double start = now(), report = start;
    for (auto &slot : slots) {
        if (stopped) break;
        slot->submit(gpu, batch, suffix, benchmark > 0);
    }
    bool draining = stopped; int exitCode = stopped ? 130 : 0;
    size_t next = 0;
    for (;;) {
        @autoreleasepool {
            PendingBatch &slot = *slots[next];
            if (slot.command) {
                uint32_t winner = slot.finish();
                if (winner) {
                    require(winner <= batch, "Invalid winner index");
                    saveKey(slot.seeds.p + (winner - 1) * 32, suffix, output);
                    fprintf(stderr, "Search elapsed: %.2f seconds (pending GPU batches are drained).\n", now() - start);
                    return 0;
                }
                sodium_memzero(slot.seeds.p, slot.seeds.n); total += batch;
            }
            double elapsed = now() - start;
            if (now() - report >= 2) {
                double rate = total / elapsed;
                fprintf(stderr, "%llu trials | %.0f keys/s | %.1fs | mean wait at this rate: %.1fs\n",
                    (unsigned long long)total, rate, elapsed, pow(64., suffix.size()) / rate);
                report = now();
            }
            if (!draining) {
                if (stopped) { draining = true; exitCode = 130; }
                else if (benchmark && elapsed >= benchmark) draining = true;
                else if (maxSeconds && elapsed >= maxSeconds) { draining = true; exitCode = 2; }
            }
            if (draining) {
                bool pending = false;
                for (auto &other : slots) if (other->command) pending = true;
                if (!pending) {
                    elapsed = now() - start;
                    fprintf(stderr, "%llu trials | %.0f keys/s | %.2fs | all pending batches completed\n",
                        (unsigned long long)total, total / elapsed, elapsed);
                    if (exitCode == 130) fprintf(stderr, "Stopped; no keypair saved.\n");
                    if (exitCode == 2) fprintf(stderr, "Time limit reached; no keypair saved.\n");
                    return exitCode;
                }
            } else slot.submit(gpu, batch, suffix, benchmark > 0);
            next = (next + 1) % slots.size();
        }
    }
}
static const char *help =
    "Optimized only for Apple M4 (10-core GPU); other devices are unverified.\n"
    "Usage: ./run.sh [--suffix 2778] [--backend metal|cpu|auto] [--output PATH]\n"
    "                [--batch 16384] [--inflight 1..4] [--threadgroup 32..1024]\n"
    "                [--benchmark SECONDS] [--max-seconds SECONDS] [--self-test]\n"
    "Default: suffix 2778, backend auto (Metal when available), output ./id_ed25519_2778\n"
    "Only the winning keypair is saved, with an empty comment and no passphrase.\n"
    "Suffix accepts 1..8 standard Base64 characters; matching is case-sensitive.\n"
    "Benchmark never saves keys. Ctrl-C stops after the in-flight GPU batch.\n";
#ifndef SSH_VANITY_NO_MAIN
int main(int argc, char **argv) {
    @autoreleasepool {
        try {
            require(sodium_init() >= 0, "libsodium initialization failed");
            umask(0077); signal(SIGINT, stopHandler); signal(SIGTERM, stopHandler);
            std::string suffix = "2778", backend = "auto", output;
            uint32_t batch = 16384, inflight = 1, threadgroup = 64;
            double benchmark = 0, maxSeconds = 0; bool selfTest = false;
            for (int i = 1; i < argc; ++i) {
                std::string arg = argv[i];
                if (arg == "--help" || arg == "-h") { printf("%s", help); return 0; }
                if (arg == "--self-test") { selfTest = true; continue; }
                require(i + 1 < argc, "Missing option value"); std::string value = argv[++i];
                if (arg == "--suffix") suffix = value;
                else if (arg == "--backend") backend = value;
                else if (arg == "--output") output = value;
                else if (arg == "--inflight" || arg == "--threadgroup") {
                    size_t used; unsigned long n = std::stoul(value, &used);
                    require(used == value.size(), "Invalid integer option");
                    if (arg == "--inflight") {
                        require(n >= 1 && n <= 4, "Inflight must be 1..4"); inflight = (uint32_t)n;
                    } else {
                        require(n >= 32 && n <= 1024 && n % 32 == 0, "Threadgroup must be a multiple of 32 in 32..1024");
                        threadgroup = (uint32_t)n;
                    }
                }
                else if (arg == "--batch") {
                    size_t used; unsigned long n = std::stoul(value, &used);
                    require(used == value.size() && n >= 1024 && n <= 1048576, "Batch must be 1024..1048576"); batch = (uint32_t)n;
                } else if (arg == "--benchmark" || arg == "--max-seconds") {
                    size_t used; double n = std::stod(value, &used);
                    require(used == value.size() && std::isfinite(n) && n > 0, "Seconds must be positive and finite");
                    if (arg == "--benchmark") benchmark = n; else maxSeconds = n;
                } else throw std::runtime_error("Unknown option: " + arg);
            }
            require(suffix.size() >= 1 && suffix.size() <= 8, "Suffix length must be 1..8");
            for (char c : suffix) require(c != '\0' && strchr(alphabet, c), "Suffix must use standard Base64 characters (no '=')");
            require(backend == "auto" || backend == "metal" || backend == "cpu", "Backend must be auto, metal or cpu");
            if (output.empty()) {
                // '/' is legal Base64, but must not create a path component.
                std::string safe = suffix; for (char &c : safe) if (c == '/') c = '_';
                output = "id_ed25519_" + safe;
            }
            struct stat st;
            if (!benchmark && !selfTest) {
                require(lstat(output.c_str(), &st) != 0 && errno == ENOENT, "Output path already exists or cannot be checked");
                require(lstat((output + ".pub").c_str(), &st) != 0 && errno == ENOENT, "Public output path already exists or cannot be checked");
            }
            NSString *root = [[[NSProcessInfo processInfo] environment] objectForKey:@"SSH_VANITY_ROOT"];
            require(root != nil, "Run through run.sh");
            bool metal = backend == "metal" || (backend == "auto" && MTLCreateSystemDefaultDevice() != nil);
            std::unique_ptr<GPU> gpu;
            if (metal) {
                gpu.reset(new GPU(batch, root));
                require(threadgroup <= gpu->pipeline.maxTotalThreadsPerThreadgroup, "Threadgroup exceeds pipeline hardware limit");
                gpu->threadgroup = threadgroup; gpu->selfTest();
                fprintf(stderr, "Backend: Metal / %s\n", gpu->device.name.UTF8String);
                fprintf(stderr, "Batch: %u | threadgroup: %u | inflight: %u\n", batch, threadgroup, inflight);
            } else fprintf(stderr, "Backend: CPU / 8 workers (libsodium)\n");
            if (selfTest) { require(metal, "Use --backend metal --self-test for GPU verification"); return 0; }
            fprintf(stderr, "Suffix: %s; average trials: %.0f. No nonmatching keys are saved.\n", suffix.c_str(), pow(64., suffix.size()));
            if (metal && inflight > 1)
                return pipelinedSearch(*gpu, batch, inflight, suffix, output, benchmark, maxSeconds);
            Secret seeds((size_t)batch * 32);
            uint64_t total = 0; double start = now(), report = start;
            while (!stopped) {
                @autoreleasepool {
                    randombytes_buf(seeds.p, seeds.n);
                    uint32_t winner = metal ? gpu->run(seeds.p, batch, suffix, benchmark ? 1 : 0)
                                             : cpuBatch(seeds.p, batch, suffix, benchmark > 0);
                    if (winner) {
                        require(winner <= batch, "Invalid winner index");
                        saveKey(seeds.p + (winner - 1) * 32, suffix, output);
                        fprintf(stderr, "Search elapsed: %.2f seconds (final batch may stop early).\n", now() - start);
                        return 0;
                    }
                    sodium_memzero(seeds.p, seeds.n); total += batch;
                    double elapsed = now() - start, rate = total / elapsed;
                    if (now() - report >= 2 || (benchmark && elapsed >= benchmark)) {
                        fprintf(stderr, "%llu trials | %.0f keys/s | %.1fs | mean wait at this rate: %.1fs\n",
                                (unsigned long long)total, rate, elapsed, pow(64., suffix.size()) / rate);
                        report = now();
                    }
                    if (benchmark && elapsed >= benchmark) return 0;
                    if (maxSeconds && elapsed >= maxSeconds) {
                        fprintf(stderr, "Time limit reached; no keypair saved.\n"); return 2;
                    }
                }
            }
            fprintf(stderr, "Stopped; no keypair saved.\n"); return 130;
        } catch (const std::exception &e) { fprintf(stderr, "Error: %s\n", e.what()); return 1; }
    }
}
#endif
