# Third-party notices

Original code in this repository is licensed under [MIT](LICENSE).

`vendor/ed25519-ref10.metal` is an extracted and altered version of
[mc-keygen](https://github.com/samschlegel/mc-keygen) at commit
`62ed67f94b061cf2eddca1403ef1004f3a2a148c`, originally licensed
`MIT OR Apache-2.0`. This distribution uses the **MIT** option and retains
Sam Schlegel's [MIT license](vendor/LICENSE-MIT).

The upstream field arithmetic and group operations also include code derived
from solana-perf-libs / SUPERCOP ref10. The original Orson Peters Zlib and
isis agora lovecruft BSD 3-Clause copyright notices, conditions and disclaimers
are retained in [vendor/THIRD-PARTY-NOTICES](vendor/THIRD-PARTY-NOTICES).
Those terms continue to apply to the corresponding portions.

The extraction is described in [vendor/PROVENANCE.md](vendor/PROVENANCE.md).
The original upstream search and scalar-walking kernels are not distributed.

libsodium is a separately installed system dependency and is not vendored here.
