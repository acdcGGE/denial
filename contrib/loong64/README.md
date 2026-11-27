# denial loongarch64 交叉编译

在 x86-64 主机上为 **loongarch64** 交叉编译 denial v0.6.10，包含：

- Flutter 引擎（`denialwm/flutter` 分支 `denial/3.47.5`）的 loong64 目标与 x86-64 host 工具
- Dart shell（`libapp.so`，AOT）
- Rust compositor（`deniald` / `denialctl` / `denial-portal`）
- 最终 payload 与校验文件

## 获取工具链与依赖

仓库内不包含任何主机绝对路径，所有路径均由 `WORK` / `SYSROOT` / `FLUTTER` 推导。

### 1. host 工具与 Rust 目标（系统仓库 / 网络）

```bash
# Arch
sudo pacman -S --needed clang lld llvm ninja gn pkgconf python curl unzip git rustup aria2
# Debian/Ubuntu
sudo apt install clang lld llvm ninja-build gn pkg-config python3 curl unzip git

rustup target add loongarch64-unknown-linux-gnu
```

### 2. loongarch64 sysroot（目标机导出或网络下载）

需包含 `libdrm gbm egl libinput libseat libudev xkbcommon gtk+-3.0 fontconfig` 的 pkg-config 与运行库，布局为 `usr/lib`、`usr/include`。

```bash
# 方式一：从目标机导出
rsync -a --delete root@<target>:/usr "$WORK/sysroot/"

# 方式二：网络下载 rootfs 压缩包（脚本自动解压）
SYSROOT_URL=https://<mirror>/archlinux-loongarch64-rootfs.tar.zst ./contrib/loong64/build.sh env
```

### 3. Flutter 引擎源码（网络）

```bash
git clone -b loong64-cross-build https://github.com/acdcGGE/flutter.git "$WORK/flutter"
cd "$WORK/flutter" && gclient sync -D    # 需要 depot_tools
```

若 `$FLUTTER` 不存在，脚本会自动 clone（并调用 `gclient sync -D`）。

### 4. Dart 3.13.4

由脚本自动从 `storage.flutter-io.cn` 下载，仅用于 `pub`。

## 使用

```bash
./contrib/loong64/build.sh all
# 或分阶段
./contrib/loong64/build.sh env engine tool shell rust payload
```

路径覆盖：`WORK`、`SYSROOT`、`SYSROOT_URL`、`FLUTTER`、`FLUTTER_URL`、`GN`、`JOBS`。默认 `WORK=${XDG_CACHE_HOME:-~/.cache}/denial-loong64`。

产物：`$WORK/payload`、`$WORK/denial-linux-loong64.tar.gz`；pacman 包用 `./contrib/loong64/package-pkg.sh` 生成到 `$WORK/pkgs`。

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
