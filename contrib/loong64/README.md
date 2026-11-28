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
./contrib/loong64/build.sh env engine tool shell rust apps payload
```

路径覆盖：`WORK`、`SYSROOT`、`SYSROOT_URL`、`FLUTTER`、`FLUTTER_URL`、`GN`、`JOBS`。默认 `WORK=${XDG_CACHE_HOME:-~/.cache}/denial-loong64`。

产物：`$WORK/payload`、`$WORK/denial-linux-loong64.tar.gz`；pacman 包用 `./contrib/loong64/package-pkg.sh` 生成到 `$WORK/pkgs`。

`apps` 阶段交叉编译独立应用：`native_app`（runner，产物 `denial-app`）、`polkit_app` 与 `plugin_manager_app`，组成 `$WORK/apps/{polkit,plugin-manager}` bundle，并并入 payload（`lib/denial/`）与 `denial` 包。

## 关键改动

- `contrib/loong64/flutter-denial-3.47.5-loongarch64.patch`：Flutter 引擎的 loong64 平台支持（GN 工具链、CPU 特性、Dart ABI、sysroot 处理等）。
- `contrib/loong64/flutter_tools-pubspec_overrides.yaml`：`code_assets` 使用 loong64 分支。
- `compositor/src/bin/deniald/plugin_bundle.rs`：插件平台字符串增加 `linux-loong64`。
- Rust 链接需 `-Wl,--unresolved-symbols=ignore-in-object-files`：`__tls_get_addr` 只由 `ld-linux-loongarch-lp64d.so.1` 提供。
- 引擎 host 构建需要的 Vulkan 头由 `CPATH` 指向 sysroot；ICU 头不要在 `CPATH` 中覆盖为引擎内的 ICU 80 头，必须与 host sysroot 的 `libicuuc` 版本一致，否则 `dartvm` / `dartaotruntime` 链接时符号命名空间（`icu_XX`）不匹配。
- 引擎自建 `dartvm` 已具备 JIT，但缺少 `dartdev`（`pub`），因此提供一层 `dart` 包装脚本：`pub` 交给官方 Dart 3.13.4，其余交给 `dartvm`。
- `dds` / `dartdev` 的 AOT snapshot 与 SDK API 不匹配属于已知无害失败，脚本以 `-k 0` 继续。
- `third_party/dart/third_party/devtools` 在上游来自 CIPD（不可达），而 dart 根 `pubspec.yaml` 以 path 依赖 `devtools_shared`；脚本会生成最小 stub（见 `DEPS` 顶部说明，上游源：https://github.com/flutter/devtools ）。

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
- sysroot 中的 ICU 头为 80、库为 78，且目标端 `libflutter_engine.so` 未链接 ICU，因此会保留未解析的 `icu_80` 符号。构建与打包不受影响；若运行期在 Unicode 正则、大小写转换等路径出现符号解析失败，需要将 sysroot 的 ICU 头对齐到 78，或为 loong64 构建并链接 ICU 80。
- `denial-polkit-agent` 依赖 sysroot 中的 `polkit-agent-1` / `polkit-gobject-1`；当前 sysroot 未提供，`apps` 阶段会跳过该后端（polkit 弹窗 bundle 仍会构建）。
- 5 个内置插件（clock/desktop/launcher/pets/top_bar）由 `dart_shell` 直接依赖并编入 `libapp.so`，无需单独打包；第三方插件的运行时编译需要设备端插件构建套件，而它依赖 loong64 的 Dart 工具链（当前只有 JIT 版 `dartvm`，缺 `dartaotruntime`/`pub`），暂不可用。
