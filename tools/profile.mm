// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rkbkosp
// Standalone tuning utility; it does not replace or modify the running search.
#define SSH_VANITY_NO_MAIN
#include "../src/vanity.mm"
#include <sys/wait.h>

struct ResumeGuard {
    pid_t target = 0, watchdog = 0;
    explicit ResumeGuard(pid_t pid) {
        if (pid <= 0) return;
        require(kill(pid, SIGSTOP) == 0, "Cannot suspend target for isolated measurement");
        target = pid;
        watchdog = fork();
        if (watchdog == 0) { sleep(30); kill(pid, SIGCONT); _exit(0); }
        if (watchdog < 0) { kill(pid, SIGCONT); target = 0; throw std::runtime_error("Cannot create resume watchdog"); }
        fprintf(stderr, "Temporarily suspended PID %d; automatic resume watchdog: 30s.\n", pid);
    }
    ~ResumeGuard() {
        if (target) { kill(target, SIGCONT); fprintf(stderr, "Resumed PID %d.\n", target); }
        if (watchdog > 0) { kill(watchdog, SIGTERM); waitpid(watchdog, nullptr, 0); }
    }
};
struct ProfileSlot {
    Secret seeds;
    id<MTLBuffer> scalars, winner, output;
    id<MTLCommandBuffer> command;
    explicit ProfileSlot(GPU &gpu, uint32_t capacity) : seeds((size_t)capacity * 32) {
        scalars = [gpu.device newBufferWithLength:seeds.n options:MTLResourceStorageModeShared];
        winner = [gpu.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        output = [gpu.device newBufferWithLength:seeds.n options:MTLResourceStorageModeShared];
        require(scalars && winner && output, "Profile buffer allocation failed");
    }
    ~ProfileSlot() {
        if (command) [command waitUntilCompleted];
        sodium_memzero(scalars.contents, scalars.length);
    }
};
struct Measurement {
    double random = 0, sha = 0, encode = 0, wait = 0, gpu = 0, clear = 0;
    uint64_t keys = 0;
};
static void finish(ProfileSlot &slot, Measurement &m) {
    if (!slot.command) return;
    double start = now(); [slot.command waitUntilCompleted]; m.wait += now() - start;
    require(slot.command.status == MTLCommandBufferStatusCompleted, "Profile GPU command failed");
    m.gpu += slot.command.GPUEndTime - slot.command.GPUStartTime;
    start = now(); sodium_memzero(slot.scalars.contents, slot.scalars.length);
    sodium_memzero(slot.seeds.p, slot.seeds.n); m.clear += now() - start;
    slot.command = nil;
}
static void submit(GPU &gpu, ProfileSlot &slot, uint32_t count, NSUInteger group,
                   uint32_t mode, Measurement &m) {
    double start = now(); randombytes_buf(slot.seeds.p, (size_t)count * 32); m.random += now() - start;
    start = now(); deriveScalars(slot.seeds.p, (unsigned char *)slot.scalars.contents, count); m.sha += now() - start;
    start = now(); memset(slot.winner.contents, 0, 4);
    unsigned char target[8] = {61,53,54,59,59,60,0,0}; // 912778
    uint32_t length = 6;
    slot.command = [gpu.queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [slot.command computeCommandEncoder];
    [encoder setComputePipelineState:gpu.pipeline];
    [encoder setBuffer:slot.scalars offset:0 atIndex:0];
    [encoder setBuffer:slot.winner offset:0 atIndex:1];
    [encoder setBytes:target length:8 atIndex:2];
    [encoder setBytes:&length length:4 atIndex:3];
    [encoder setBytes:&count length:4 atIndex:4];
    [encoder setBytes:&mode length:4 atIndex:5];
    [encoder setBuffer:slot.output offset:0 atIndex:6];
    [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(group,1,1)];
    [encoder endEncoding]; [slot.command commit]; m.encode += now() - start;
    m.keys += count;
}
static void validate(GPU &gpu, ProfileSlot &slot, NSUInteger group) {
    Measurement m; submit(gpu, slot, 1024, group, 2, m);
    [slot.command waitUntilCompleted];
    require(slot.command.status == MTLCommandBufferStatusCompleted, "Profile validation GPU error");
    unsigned char pub[32], secret[64];
    for (uint32_t i = 0; i < 1024; ++i) {
        crypto_sign_seed_keypair(pub, secret, slot.seeds.p + 32*i);
        sodium_memzero(secret, sizeof(secret));
        require(memcmp(pub, (unsigned char *)slot.output.contents + 32*i, 32) == 0,
                "Threadgroup setting failed independent CPU validation");
    }
    finish(slot, m);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        try {
            require(sodium_init() >= 0, "sodium init failed");
            signal(SIGINT, stopHandler); signal(SIGTERM, stopHandler);
            const uint32_t capacity = 131072;
            NSString *root = [[[NSProcessInfo processInfo] environment] objectForKey:@"SSH_VANITY_ROOT"];
            require(root != nil, "Run through scripts/profile.sh");
            GPU gpu(capacity, root);
            std::unique_ptr<ProfileSlot> slots[3];
            for (auto &slot : slots) slot.reset(new ProfileSlot(gpu, capacity));
            fprintf(stderr, "Device=%s simd_width=%lu max_group=%lu static_threadgroup_memory=%lu\n",
                    gpu.device.name.UTF8String, gpu.pipeline.threadExecutionWidth,
                    gpu.pipeline.maxTotalThreadsPerThreadgroup, gpu.pipeline.staticThreadgroupMemoryLength);
            for (NSUInteger group : {32,64,128,256}) {
                if (group > gpu.pipeline.maxTotalThreadsPerThreadgroup) continue;
                validate(gpu, *slots[0], group);
            }
            fprintf(stderr, "All tested threadgroup sizes passed 1024 CPU/GPU comparisons each.\n");
            pid_t pausePid = 0; bool focused = false;
            for (int i = 1; i < argc; ++i) {
                std::string arg = argv[i];
                if (arg == "--focused") focused = true;
                else if (arg == "--pause-pid" && i + 1 < argc) {
                    std::string value = argv[++i]; size_t used;
                    unsigned long n = std::stoul(value, &used);
                    require(used == value.size() && n > 1 && n <= INT_MAX && (pid_t)n != getpid(), "Invalid pause PID");
                    pausePid = (pid_t)n;
                } else if (arg == "--help") {
                    printf("Usage: scripts/profile.sh [--focused] [--pause-pid PID]\n"
                           "--pause-pid explicitly suspends that process during the sweep, then resumes it.\n");
                    return 0;
                } else throw std::runtime_error("Unknown profile option: " + arg);
            }
            ResumeGuard resume(pausePid);
            double suiteStart = now();
            printf("batch,group,inflight,keys,wall_s,keys_per_s,random_ms,sha_ms,encode_ms,wait_ms,gpu_ms,clear_ms\n");
            // Paired repeated baselines reduce the effect of clock/temperature drift.
            struct Config { uint32_t batch; NSUInteger group; int depth; };
            std::vector<Config> configs = {{16384,64,1}};
            for (uint32_t batch : {4096u,16384u,65536u,131072u})
                for (NSUInteger group : {32u,64u,128u,256u})
                    configs.push_back({batch, group, 1});
            for (uint32_t batch : {16384u,65536u})
                for (int depth : {2,3}) configs.push_back({batch,64,depth});
            configs.push_back({16384,64,1});
            double duration = .40;
            if (focused) {
                duration = 1.5;
                configs = {{16384,64,1},{65536,64,1},{16384,64,2},
                           {16384,64,3},{65536,64,2},{16384,64,1}};
            }
            for (auto c : configs) {
                if (stopped || now() - suiteStart > 23) break;
                if (c.group > gpu.pipeline.maxTotalThreadsPerThreadgroup) continue;
                @autoreleasepool {
                    Measurement m;
                    double start = now(); size_t submitted = 0;
                    while (now() - start < duration && !stopped) {
                        ProfileSlot &slot = *slots[submitted % c.depth];
                        finish(slot,m); submit(gpu,slot,c.batch,c.group,1,m); ++submitted;
                    }
                    for (int i=0;i<c.depth;++i) finish(*slots[i],m);
                    double wall = now() - start;
                    printf("%u,%lu,%d,%llu,%.6f,%.0f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                        c.batch,c.group,c.depth,(unsigned long long)m.keys,wall,m.keys/wall,
                        m.random*1000,m.sha*1000,m.encode*1000,m.wait*1000,m.gpu*1000,m.clear*1000);
                    fflush(stdout);
                }
            }
            return 0;
        } catch(const std::exception &e) { fprintf(stderr,"Profile error: %s\n",e.what()); return 1; }
    }
}
