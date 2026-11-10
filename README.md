# SSH Key Vanity · Apple M4

批量生成标准 OpenSSH Ed25519 密钥，精确匹配公钥 **Base64 字段末尾**，找到一对就停止。非命中候选只存在于内存中，不保存到磁盘，也不使用注释拼接后缀。

**仅针对 Apple M4（10 核 GPU）优化和实测。** 其他 Apple 芯片（包括 M4 Pro/Max）未经验证，不承诺相同性能。

**Optimized and benchmarked only for Apple M4 (10-core GPU).** Other Apple Silicon models are unverified. Original project code is MIT licensed; third-party notices are retained.

## 安装与运行

需要 macOS、Xcode Command Line Tools 和 libsodium，无 Python 依赖。Metal 使用系统运行时编译器，无需额外下载离线 Metal Toolchain。

```sh
xcode-select --install   # 已安装 Command Line Tools 时可跳过
brew install libsodium
cd ssh-key-vanity         # 进入源码目录

# M4 推荐：每批 16384 个，两个在途批次
./run.sh --suffix 2778 --inflight 2 --output ./my_key
```

首次运行自动编译。命中后生成 `my_key` 与 `my_key.pub`，公钥不含注释；已有路径会报错，输出目录需要提前存在。私钥权限为 `0600`，默认无口令。如需口令：

```sh
ssh-keygen -p -f ./my_key
```

手动构建可用 `./scripts/build.sh`。如 libsodium 位于其他目录，通过 `SODIUM_ROOT` 指定其安装前缀。

## 参数

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--suffix` | `2778` | 1～8 位标准 Base64 字符，大小写敏感，不接受 `=` |
| `--backend` | `auto` | `auto`、`metal` 或 `cpu`；auto 在有 Metal 时使用 GPU |
| `--output` | 当前目录的 `id_ed25519_<suffix>` | 最终私钥路径；公钥追加 `.pub`，默认文件名中的 `/` 自动替换为 `_` |
| `--batch` | `16384` | 每批候选数量，范围 1024～1048576 |
| `--inflight` | `1` | Metal 在途批次，范围 1～4；M4 推荐 2 |
| `--threadgroup` | `64` | Metal 线程组大小，32 的倍数且不超过管线限制 |
| `--benchmark` | 关闭 | 测速秒数，不保存密钥 |
| `--max-seconds` | 不限制 | 搜索时间限制，启动编译和自检不计入 |
| `--self-test` | 关闭 | 验证 GPU 后退出，不执行搜索 |

```sh
./run.sh --backend cpu --suffix 2778 --output ./cpu_key
./run.sh --backend metal --suffix 912778 --inflight 2 --output ./long_key
./run.sh --backend metal --benchmark 10 --inflight 2
./run.sh --backend metal --self-test
```

Ctrl-C 或 SIGTERM 请求停止；在途 GPU 批次完成后清理退出。已完成批次如包含命中，仍会验证并保存这唯一一对。进程被 SIGKILL 强制结束时无法执行应用层清理。退出码：成功或测速完成为 0，错误为 1，未命中到达时间限制为 2，中断未命中为 130。

## M4 性能

本机 macOS 27.2、Apple M4、10 核 CPU / 10 核 GPU、16 GiB 内存，短测包含安全随机种子生成、CPU 准备和 GPU 计算，不含启动自检：

| 模式 | 实测吞吐 |
| --- | ---: |
| CPU，8 个工作线程 | 约 49 万个/秒 |
| Metal，单个在途批次 | 约 131 万个/秒 |
| Metal，两个在途批次 | **约 297 万个/秒** |
| Metal，三个在途批次 | 约 301 万个/秒 |

双缓冲在本实现的短测中约提速 2.26 倍。它同时准备后续批次和执行 GPU 工作；每个批次独占种子、标量和结果缓冲区，完成后才复用。

四位后缀平均需要约 1678 万次尝试；六位约 687 亿次，在 297 万个/秒下平均约 **6.4 小时**。八位仍平均需要约 **3 年**。这些是概率估算，不能保证在平均时间内找到结果。

数据、测量限制与复现命令见 [M4 性能记录](docs/BENCHMARKS.md)。

## 密钥生成与验证

- 每个候选使用 libsodium 的系统安全随机源生成全新的 32 字节种子。候选种子由 `sodium_malloc` 管理；不记录种子、不保存恢复文件。
- Metal 模式由 CPU 执行 SHA-512/clamp，GPU 执行 Ed25519 基点乘法、公钥编码和后缀匹配。CPU 模式使用 libsodium，固定 8 个工作线程。
- 启动 Metal 时，将 1 个 RFC 8032 测试种子与 1023 个随机种子的 GPU 公钥逐个与 libsodium 比较，再验证 1～8 位后缀匹配路径。
- 命中后，CPU 从种子重新生成公钥，使用 Foundation 的 Base64 编码独立匹配，并完成签名/验签，最后才写入最终一对密钥。
- 正常批次完成后清零候选种子和共享标量缓冲区；命中、中断或超时后，等待已经提交的 GPU 工作收尾，不再提交新批次。
- 可执行程序不联网。该工具尚未经过独立密码学安全审计。

## 开发与测试

```sh
./tests/smoke.sh           # CPU：命中、无注释、权限、禁止覆盖、OpenSSH 签名/验签
./tests/smoke.sh --metal   # 同样验证 Metal 并发 1、2、3、4
./scripts/profile.sh --focused > tuning.csv
```

测试只生成临时测试密钥并在退出时移除。不要同时运行搜索与性能测试，否则结果会受 GPU 竞争影响。

```text
src/       主程序与搜索内核
vendor/    Ed25519 ref10 运算及原始许可
scripts/   构建、性能诊断入口
tools/     性能诊断源码
tests/     OpenSSH 回验
docs/      M4 性能记录与无敏感信息的 CSV
build/     本地构建产物，Git 忽略
.local/    本地原始证据，Git 忽略
```

仓库根目录采用 Git 文件白名单，任意命名的输出密钥和本地构建文件默认不跟踪；发布时仍应检查暂存区。

## License / 来源

项目原创代码采用 [MIT License](LICENSE)。第三方 Ed25519 运算代码保留原有 MIT、Zlib 与 BSD 3-Clause 通知，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [来源记录](vendor/PROVENANCE.md)。

格式依据：[RFC 8709](https://www.rfc-editor.org/rfc/rfc8709.html)、[RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html)、[OpenSSH PROTOCOL.key](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key)。
