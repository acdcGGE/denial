# denial loongarch64 原生构建

在 x86-64 主机上为 **loongarch64** 交叉编译 denial v0.6.10，包含：

- Flutter 引擎（`denialwm/flutter` 分支 `denial/3.47.5`）的 loong64 目标与 x86-64 host 工具
- Dart shell（`libapp.so`，AOT）
- Rust compositor（`deniald` / `denialctl` / `denial-portal`）
- 最终 payload 与校验文件

## 依赖

| 组件 | 说明 |
| --- | --- |
| loongarch64 sysroot | 需包含 `libdrm gbm egl libinput libseat libudev xkbcommon gtk+-3.0 fontconfig` 的 pkg-config 与运行库 |
| clang / lld / llvm-ar | 交叉编译与链接（**不要**用 `loongarch64-linux-gnu-ld`） |
| gn / ninja | 引擎构建 |
| Rust | `rustup target add loongarch64-unknown-linux-gnu` |
| denialwm/flutter | 检出 `denial/3.47.5` 分支（默认 `$WORK/checkout`） |
| Dart 3.13.4 | 仅用于 `pub`，脚本会自动下载（国内镜像） |

## 使用

```bash
# 全部阶段
./contrib/loong64/build.sh all

# 或分阶段执行
./contrib/loong64/build.sh env engine tool shell rust payload
```

可通过环境变量覆盖路径：`WORK`、`SYSROOT`、`FLUTTER`、`GN`、`JOBS`。

产物：`$WORK/payload` 与 `$WORK/denial-linux-loong64.tar.gz`。

## 关键改动

- `contrib/loong64/flutter-denial-3.47.5-loongarch64.patch`：Flutter 引擎的 loong64 平台支持（GN 工具链、CPU 特性、Dart ABI、sysroot 处理等）。
- `contrib/loong64/flutter_tools-pubspec_overrides.yaml`：`code_assets` 使用 loong64 分支。
- `compositor/src/bin/deniald/plugin_bundle.rs`：插件平台字符串增加 `linux-loong64`。
- Rust 链接需 `-Wl,--unresolved-symbols=ignore-in-object-files`：`__tls_get_addr` 只由 `ld-linux-loongarch-lp64d.so.1` 提供。
- 引擎 host 构建需要 Vulkan / ICU 头文件；脚本通过 `CPATH` 指向 sysroot 与引擎 ICU 源码。
- 引擎自建 `dartvm` 已具备 JIT，但缺少 `dartdev`（`pub`），因此提供一层 `dart` 包装脚本：`pub` 交给官方 Dart 3.13.4，其余交给 `dartvm`。
- `dds` / `dartdev` 的 AOT snapshot 与 SDK API 不匹配属于已知无害失败，脚本以 `-k 0` 继续。

## 运行

目标设备需具备上述 sysroot 运行库。

```bash
cd payload && sha256sum -c SHA256SUMS

DENIAL_SHELL_PROFILE=mobile bin/deniald \
  --device /dev/dri/card0 --output-config outputs.conf \
  --wayland --flutter-bundle bundle
```

## 已知限制

- 构建时关闭了 `TreeShakeIcons`（host 端 `const_finder` / `font-subset` 未构建），仅影响图标字体体积。
- `settings`（GPUI）与插件 bundle 不在 payload 范围内。
- 预编译 payload 与引擎产物见对应 tag 的 Release 附件。
