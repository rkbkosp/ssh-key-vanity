// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rkbkosp
// Search kernel for standard, seed-derived OpenSSH Ed25519 keys.
// Field/group operations are in vendor/ed25519-ref10.metal.
kernel void ssh_vanity(
    const device uchar *scalars [[buffer(0)]],
    device atomic_uint *winner [[buffer(1)]],
    constant uchar *target [[buffer(2)]],
    constant uint &length [[buffer(3)]],
    constant uint &count [[buffer(4)]],
    constant uint &mode [[buffer(5)]],
    device uchar *verification [[buffer(6)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid >= count) return;
    // mode 0: search; 1: full benchmark; 2: export public keys for self-test.
    if (mode == 0 && atomic_load_explicit(winner, memory_order_relaxed)) return;
    uchar scalar[32], pub[32];
    for (uint i = 0; i < 32; ++i) scalar[i] = scalars[32 * tid + i];
    ge_p3 point;
    ge_scalarmult_base(&point, scalar);
    ge_p3_tobytes(pub, &point);
    if (mode != 0) {
        // Observable output prevents the optimizer from skipping key generation
        // in benchmark mode. Only public keys are written to this RAM buffer.
        for (uint i = 0; i < 32; ++i) verification[32 * tid + i] = pub[i];
        return;
    }
    // The SSH wire blob is 19 header bytes + 32 public-key bytes, hence
    // exactly 68 Base64 characters, without '='. Last 8 chars cover pub[26:32].
    bool matches = true;
    for (uint i = 0; i < length; ++i) {
        uint bit = (68 - length + i) * 6;
        uint byte = bit / 8 - 19;
        uint word = uint(pub[byte]) << 8;
        if (byte < 31) word |= pub[byte + 1];
        if (((word >> (10 - (bit % 8))) & 63) != target[i]) matches = false;
    }
    if (mode == 0 && matches) {
        uint expected = 0;
        while (!atomic_compare_exchange_weak_explicit(winner, &expected, tid + 1,
                    memory_order_relaxed, memory_order_relaxed)) {
            if (expected != 0) break;
        }
    }
}
