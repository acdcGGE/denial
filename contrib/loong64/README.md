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
git clone -b loong64-cross-build https://github.com/acdcGGE/denial-flutter.git "$WORK/flutter"
cd "$WORK/flutter" && gclient sync -D    # 需要 depot_tools
```

若 `$FLUTTER` 不存在，脚本会自动 clone（并调用 `gclient sync -D`）。

宿主需要 x86 的 `flatc`（引擎补丁用它生成 FlatBuffers 代码，不执行目标端二进制）：安装系统 `flatbuffers` 包，或手动把 `flatc` 放到 `/tmp/flatc`。

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

`apps` 阶段交叉编译独立应用：`native_app`（runner，产物 `denial-app`）、`polkit_app` 与 `plugin_manager_app`，组成 `$WORK/apps/{polkit,plugin-manager}` bundle，并并入 payload（`lib/denial/`）与 `denial` 包。同时把 `packages/denial_plugin_manager` 交叉编成 loong64 AOT ELF（`$WORK/apps/plugin-manager-backend/denial-plugins.so`），随 `denial` 包安装为 `/usr/bin/denial-plugins`（`dartaotruntime` 包装脚本）。

## 关键改动

- `contrib/loong64/flutter-denial-3.47.5-loongarch64.patch`：Flutter 引擎的 loong64 平台支持（GN 工具链、CPU 特性、Dart ABI、sysroot 处理等）。
- `contrib/loong64/loong64-no-as-needed.patch`：loong64 链接使用 `--unresolved-symbols=ignore-in-object-files` 时，`--as-needed` 会把 ICU/expat 从 `DT_NEEDED` 丢弃，留下运行期未解析符号；补丁在其后恢复 `--no-as-needed`。
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
- sysroot 中的 ICU 头为 80、库为 78。引擎按引擎内 ICU 80 头编译，因此 `stage_engine` 会用引擎自带的 ICU 80 源码交叉编译 loong64 共享库（`$WORK/icu80`，安装进 sysroot 供链接）。ICU 数据由 Dart/Flutter 启动时通过 `udata_setCommonData` 注入 `icudtl.dat`，所以只携带 ICU 的 stubdata。产物 `libicuuc.so.80` / `libicui18n.so.80` / `libicudata.so.80` 随 `denial-flutter-engine` 安装到 `/usr/lib/denial/flutter/lib`，并通过 `/etc/ld.so.conf.d/denial-flutter-engine.conf` 注册。
- `denial-polkit-agent` 需要 sysroot 中的 `polkit-agent-1` / `polkit-gobject-1`（Devel 版含头文件与 pkg-config）。可从 Debian sid 的 loong64 包补齐：下载 `libpolkit-gobject-1-0`、`libpolkit-agent-1-0`、`libpolkit-gobject-1-dev`、`libpolkit-agent-1-dev`（`https://deb.debian.org/debian/pool/main/p/policykit-1/`），解包后把 `usr/include/polkit-1` 拷到 `$SYSROOT/usr/include`、`usr/lib/loongarch64-linux-gnu/libpolkit-*` 拷到 `$SYSROOT/usr/lib`，并把 `.pc` 的 `libdir` 改为 `${prefix}/lib`。缺少时 `apps` 阶段会跳过该后端（polkit 弹窗 bundle 仍会构建）。
- 5 个内置插件（clock/desktop/launcher/pets/top_bar）由 `dart_shell` 直接依赖并编入 `libapp.so`，无需单独打包；第三方插件的运行时编译需要设备端插件构建套件（flutter 工具链 + 3.13.1 前端 + 构建缓存），当前未提供；`denial-plugins` 后端本身已随 `denial` 包安装，可处理状态查询。
- 插件管理器后端的 AOT 管线：host 侧用引擎自建的 `frontend_server_aot.dart.snapshot` 编译 kernel（必须 `--target=vm` + `--platform $TARGET_OUT/vm_platform.dill`；用 `flutter_patched_sdk` 会缺 `dart:_builtin`，`dartaotruntime` 启动报错），再用交叉 `gen_snapshot_product_linux_loong64` 产出 app-aot-elf，由 loong64 `dartaotruntime` 运行。引擎内 Dart 为 3.13.1，与官方 SDK 3.13.x 编出的 kernel 不兼容，必须用引擎自己的前端。
