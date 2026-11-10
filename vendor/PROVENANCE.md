The field arithmetic, base-point table and group operations in
`ed25519-ref10.metal` were extracted (lines 1..3264) from:

- https://github.com/samschlegel/mc-keygen
- commit `62ed67f94b061cf2eddca1403ef1004f3a2a148c`
- source `metal/vanity_kernel.metal`

This is an altered/extracted source version. The original MeshCore search,
scalar-walking and verification kernels were removed. This utility uses fresh
random 32-byte seeds, standard SHA-512/clamping and full base-point
multiplication for every candidate, so its output is a standard OpenSSH
Ed25519 key. It does not use scalar walking (which cannot recover the standard
Ed25519 seed).

Trailing whitespace and the final extra blank line were normalized during
repository preparation. No field/group arithmetic was changed.

Retained licenses: `LICENSE-MIT`, `THIRD-PARTY-NOTICES` (Zlib and BSD 3-Clause).
The retained upstream header describes both original upstream license choices.
