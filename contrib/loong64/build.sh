#!/usr/bin/env bash
# denial v0.6.10 loongarch64 交叉编译脚本（在 x86-64 主机上编译出 loong64 产物）
#
# 用法:
#   ./contrib/loong64/build.sh <stage> [stage...]
#   stage: env | engine | tool | shell | rust | apps | payload | all
#
# 可覆盖的环境变量:
#   WORK           构建根目录            (默认 ${XDG_CACHE_HOME:-~/.cache}/denial-loong64)
#   SYSROOT        loongarch64 sysroot   (默认 $WORK/sysroot)
#   SYSROOT_URL    sysroot 压缩包地址     (SYSROOT 不存在时自动下载)
#   FLUTTER        denialwm/flutter 检出  (默认 $WORK/flutter，不存在时自动 clone)
#   FLUTTER_URL    flutter 仓库地址       (默认 https://github.com/acdcGGE/flutter.git)
#   GN             gn 可执行文件         (默认 PATH 中的 gn)
#   JOBS           并行度                (默认 16)
set -euo pipefail

DENIAL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=${WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/denial-loong64}
SYSROOT=${SYSROOT:-$WORK/sysroot}
SYSROOT_URL=${SYSROOT_URL:-}
FLUTTER=${FLUTTER:-$WORK/flutter}
FLUTTER_URL=${FLUTTER_URL:-https://github.com/acdcGGE/flutter.git}
GN=${GN:-gn}
JOBS=${JOBS:-16}

ENGINE_SRC=$FLUTTER/engine/src
TARGET_OUT=$FLUTTER/engine/src/flutter/out/denial_linux_loong64_release
HOST_OUT=$WORK/host-build/out/denial_host_release
VIEW=$WORK/engine-view
SHELL_OUT=$WORK/shell-assembly
APPS_OUT=$WORK/apps
PAYLOAD=$WORK/payload
RUST_TARGET_DIR=$WORK/rust
TARGET_TRIPLE=loongarch64-unknown-linux-gnu

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

stage_env() {
  log "检查构建环境"
  local missing=()
  for t in clang clang++ llvm-ar ninja pkg-config python3 curl unzip git rustup; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  command -v "$GN" >/dev/null || missing+=("gn")
  if [ ${#missing[@]} -gt 0 ]; then
    cat >&2 <<EOF
缺少命令: ${missing[*]}
请从系统仓库安装（包名以发行版为准）:
  Arch:          pacman -S --needed clang lld llvm ninja gn pkgconf python curl unzip git rustup
  Debian/Ubuntu: apt install clang lld llvm ninja-build gn pkg-config python3 curl unzip git
安装 Rust 目标:
  rustup target add loongarch64-unknown-linux-gnu
EOF
    exit 1
  fi

  if [ ! -d "$SYSROOT/usr/lib" ]; then
    [ -n "$SYSROOT_URL" ] || die "sysroot 不存在: $SYSROOT（用 SYSROOT 指定，或设置 SYSROOT_URL 自动下载）"
    mkdir -p "$WORK" "$SYSROOT"
    local archive=$WORK/sysroot.tar.zst
    if command -v aria2c >/dev/null; then
      aria2c -x8 -s8 -o "$(basename "$archive")" -d "$WORK" "$SYSROOT_URL"
    else
      curl -L --retry 3 -o "$archive" "$SYSROOT_URL"
    fi
    tar -xaf "$archive" -C "$SYSROOT"
  fi

  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
  export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/lib/loongarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig
  for p in libdrm gbm egl libinput libseat libudev xkbcommon gtk+-3.0 fontconfig; do
    pkg-config --exists "$p" || die "sysroot 缺少 pkg-config 依赖: $p"
  done

  # rustup 默认源在部分网络下不可达，默认走国内镜像（可用环境变量覆盖）
  export RUSTUP_DIST_SERVER=${RUSTUP_DIST_SERVER:-https://rsproxy.cn}
  export RUSTUP_UPDATE_ROOT=${RUSTUP_UPDATE_ROOT:-https://rsproxy.cn/rustup}
  if [ ! -d "$(rustc --print sysroot)/lib/rustlib/$TARGET_TRIPLE" ]; then
    rustup target add "$TARGET_TRIPLE"
  fi

  if [ ! -d "$FLUTTER/engine/src" ]; then
    git clone --depth 1 -b loong64-cross-build "$FLUTTER_URL" "$FLUTTER"
    if command -v gclient >/dev/null; then
      # 生成 .gclient（仓库本身不含）：solution 为仓库根，依赖路径才与上游一致
      local rev
      rev=$(git -C "$FLUTTER" rev-parse HEAD)
      cat > "$FLUTTER/.gclient" <<EOF
solutions = [
  {
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": True,
    "name": ".",
    "url": "https://github.com/acdcGGE/flutter.git@$rev",
  },
]
EOF
      ( cd "$FLUTTER" && gclient sync -D --no-history -j4 --nohooks )
    else
      die "需要 depot_tools 的 gclient 同步引擎依赖（见 README）"
    fi
  fi

  # dart 的 BUILD.gn 需要 gclient 生成的参数文件（不随仓库提交）
  local dart_args=$FLUTTER/engine/src/flutter/third_party/dart/build/config/gclient_args.gni
  if [ ! -f "$dart_args" ]; then
    printf '# Auto-generated minimal gclient args for manual sync\ncheckout_llvm = false\nbuild_devtools_from_sources = false\n' > "$dart_args"
  fi

  # flutter 源码按 third_party/icu/source 布局引用，上游仓库实际是 icu4c/source
  ln -sfn icu4c/source "$FLUTTER/engine/src/flutter/third_party/icu/source"

  # Flutter 的内部镜像仓库才带 third_party 构建脚本，GitHub 上游仓库没有，统一补齐
  local tp=$FLUTTER/engine/src/flutter/third_party
  local gn_src=$FLUTTER/engine/src/flutter/loong64/third_party_gn
  if [ -d "$gn_src" ]; then
    while IFS= read -r f; do
      mkdir -p "$tp/$(dirname "$f")"
      cp -f "$gn_src/$f" "$tp/$f"
    done < <(cd "$gn_src" && find . -name BUILD.gn)
    [ -f "$gn_src/flatbuffers/copy_flatc.py" ] && cp -f "$gn_src/flatbuffers/copy_flatc.py" "$tp/flatbuffers/"
  fi

  # 上游源码缺少 loongarch64 架构识别（如 boringssl target.h），按其源码目录布局覆盖
  local files_src=$FLUTTER/engine/src/flutter/loong64/third_party_files
  if [ -d "$files_src" ]; then
    while IFS= read -r f; do
      mkdir -p "$tp/$(dirname "$f")"
      cp -f "$files_src/$f" "$tp/$f"
    done < <(cd "$files_src" && find . -type f)
  fi

  # swiftshader 的真实仓库在 loong64 上会触发内置 LLVM 断言，仅测试需要，用 stub 顶替
  local stub=$FLUTTER/engine/src/flutter/loong64/third_party_stubs/swiftshader
  if [ -d "$stub" ]; then
    rm -rf "$tp/swiftshader"
    cp -a "$stub" "$tp/swiftshader"
  fi

  # icudtl.dat 由 Flutter 的 icu 镜像提供（体积小，随 loom64 目录一起分发）
  mkdir -p "$tp/icu/flutter"
  [ -f "$tp/icu/flutter/icudtl.dat" ] || cp -f "$FLUTTER/engine/src/flutter/loong64/icu/flutter/icudtl.dat" "$tp/icu/flutter/icudtl.dat"

  # 宿主工具链需要该 sysroot 目录存在（实际使用宿主机库）
  local host_sysroot=$FLUTTER/engine/src/build/linux/debian_bullseye_amd64-sysroot
  if [ ! -d "$host_sysroot" ]; then
    mkdir -p "$host_sysroot"
    ln -sfn /usr "$host_sysroot/usr"
    ln -sfn /lib "$host_sysroot/lib"
    ln -sfn /lib64 "$host_sysroot/lib64"
  fi

  # 宿主 flatc 产物在输出根目录，impeller 规则期望 clang_x64/flatc
  mkdir -p "$TARGET_OUT/clang_x64"
  ln -sfn ../flatc "$TARGET_OUT/clang_x64/flatc"

  # CIPD 的 devtools 源（dart/third_party/flutter/devtools）不可达，
  # 而 dart 根 pubspec 以 path 依赖 third_party/devtools/devtools_shared，
  # 生成最小 stub 以保证 dart pub get 可执行。
  local dev=$FLUTTER/engine/src/flutter/third_party/dart/third_party/devtools/devtools_shared
  if [ ! -f "$dev/pubspec.yaml" ]; then
    mkdir -p "$dev/lib"
    cat > "$dev/pubspec.yaml" <<'YAML'
name: devtools_shared
version: 1.0.0
environment:
  sdk: '>=3.13.0 <4.0.0'
YAML
    printf '// Stub for devtools_shared\nlibrary devtools_shared;\n' > "$dev/lib/devtools_shared.dart"
  fi
}

stage_engine() {
  log "编译 loongarch64 引擎与 host 引擎"
  case "$(command -v python3)" in
    *depot_tools*)
      die "PATH 中 depot_tools 排在系统路径之前，python3 会被解析为未初始化的包装脚本；请把 depot_tools 放到 PATH 末尾" ;;
  esac

  # 引擎构建需要 bootstrap Dart SDK；gclient 的 download_dart_sdk 钩子在 --nohooks 下不会执行
  ensure_tool_dart
  local boot_sdk=$FLUTTER/engine/src/flutter/third_party/dart/tools/sdks/dart-sdk
  if [ ! -x "$boot_sdk/bin/dart" ]; then
    mkdir -p "$(dirname "$boot_sdk")"
    ln -sfn "$WORK/tool-dart-sdk/dart-sdk" "$boot_sdk"
  fi

  # dart 源码需要 package_config.json（gclient 钩子同样被跳过）
  ( cd "$FLUTTER/engine/src/flutter/third_party/dart" && \
    "$WORK/tool-dart-sdk/dart-sdk/bin/dart" pub get >/dev/null )
  if ! git -C "$FLUTTER" apply --reverse --check \
      "$DENIAL_ROOT/contrib/loong64/flutter-denial-3.47.5-loongarch64.patch" >/dev/null 2>&1; then
    git -C "$FLUTTER" apply "$DENIAL_ROOT/contrib/loong64/flutter-denial-3.47.5-loongarch64.patch"
  fi
  mkdir -p "$FLUTTER/packages/flutter_tools"
  cp "$DENIAL_ROOT/contrib/loong64/flutter_tools-pubspec_overrides.yaml" \
     "$FLUTTER/packages/flutter_tools/pubspec_overrides.yaml"

  # host 编译所需的 Vulkan 头文件来自 sysroot；ICU 头文件不要在此覆盖，
  # 必须与 host sysroot 中的 libicuuc（系统 ICU）版本一致，否则符号命名空间
  # （icu_XX）不匹配导致 dartvm/dartaotruntime 链接失败。
  mkdir -p "$WORK/host-deps/include"
  ln -sfn "$SYSROOT/usr/include/vulkan"   "$WORK/host-deps/include/vulkan"
  ln -sfn "$SYSROOT/usr/include/vk_video" "$WORK/host-deps/include/vk_video"
  rm -f "$WORK/host-deps/include/unicode"

  # 引擎默认从 CIPD 下载 clang；离线/受限网络下回退到系统仓库的 clang
  local bt=$ENGINE_SRC/flutter/buildtools/linux-x64/clang/bin
  if [ ! -x "$bt/clang" ]; then
    mkdir -p "$bt"
    for t in clang clang++ llvm-ar llvm-nm llvm-objcopy llvm-readelf; do
      ln -sfn "$(command -v "$t")" "$bt/$t"
    done
  fi

  mkdir -p "$TARGET_OUT" "$HOST_OUT"
  sed "s|@SYSROOT@|$SYSROOT|g" \
      "$DENIAL_ROOT/contrib/loong64/args/denial_linux_loong64_release.args.gn" > "$TARGET_OUT/args.gn"
  sed "s|@SYSROOT@|$SYSROOT|g" \
      "$DENIAL_ROOT/contrib/loong64/args/denial_host_release.args.gn" > "$HOST_OUT/args.gn"

  ( cd "$ENGINE_SRC"
    "$GN" gen "$TARGET_OUT" --root=. --script-executable="$(command -v python3)"
    "$GN" gen "$HOST_OUT"   --root=. --script-executable="$(command -v python3)" )

  ( cd "$ENGINE_SRC" && ninja -C "$TARGET_OUT" -j"$JOBS" \
      libflutter_engine.so libflutter_linux_gtk.so impellerc flatc \
      gen_snapshot dartaotruntime flutter_patched_sdk \
      flutter/shell/platform/linux:publish_headers_linux )

  # dds/dartdev 的 AOT snapshot 与 SDK API 不匹配，属于已知无害失败
  CPATH=$WORK/host-deps/include ninja -C "$HOST_OUT" -k 0 -j"$JOBS" \
      dart_sdk flutter/sky/packages/sky_engine:sky_engine \
      flutter_patched_sdk/platform_strong.dill gen_snapshot impellerc \
      flutter/shell/platform/linux:publish_headers_linux || true
  [ -x "$HOST_OUT/dartvm" ] || die "host 引擎构建失败"

  # 生成 flutter 交叉构建视图
  rm -rf "$VIEW"; mkdir -p "$VIEW/out/denial_linux_loong64_release"
  ln -sfn "$ENGINE_SRC/flutter" "$VIEW/flutter"
  ln -sfn "$HOST_OUT" "$VIEW/out/denial_host_release"
  for p in "$TARGET_OUT"/*; do
    n=${p##*/}; [ "$n" = gen_snapshot ] && continue
    ln -sfn "$p" "$VIEW/out/denial_linux_loong64_release/$n"
  done
  # flutter_tools 在 target out 的 clang_x64/ 下查找能在宿主机运行的 gen_snapshot，
  # 交叉构建使用 host 上按 loongarch64 目标生成的 product 版
  local cross_snap=$HOST_OUT/gen_snapshot_product_linux_loong64
  [ -x "$cross_snap" ] || die "缺少 host 交叉 gen_snapshot: $cross_snap"
  ln -sfn "$cross_snap" "$TARGET_OUT/clang_x64/gen_snapshot"
  ln -sfn "$cross_snap" "$TARGET_OUT/clang_x64/gen_snapshot_product"
  ln -sfn "$TARGET_OUT/clang_x64/gen_snapshot" "$VIEW/out/denial_linux_loong64_release/gen_snapshot"
  ln -sfn "$TARGET_OUT/clang_x64/gen_snapshot" "$VIEW/out/denial_linux_loong64_release/gen_snapshot_loong64"

  # assemble 需要 icudtl.dat 与 host 版 libflutter_linux_gtk.so（后者仅被复制，不参与运行）
  ICU_DATA=$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat
  cp -f "$ICU_DATA" "$TARGET_OUT/icudtl.dat"
  ln -sfn "$TARGET_OUT/icudtl.dat" "$VIEW/out/denial_linux_loong64_release/icudtl.dat"
  cp -f "$ICU_DATA" "$HOST_OUT/icudtl.dat"
  [ -e "$HOST_OUT/libflutter_linux_gtk.so" ] || \
    cp -f "$TARGET_OUT/libflutter_linux_gtk.so" "$HOST_OUT/libflutter_linux_gtk.so"
}

ensure_tool_dart() {
  local dartsdk=$WORK/tool-dart-sdk/dart-sdk
  if [ ! -x "$dartsdk/bin/dart" ]; then
    mkdir -p "$WORK/tool-dart-sdk"
    local zip=$WORK/tool-dart.zip
    local url=https://storage.flutter-io.cn/dart-archive/channels/stable/release/3.13.4/sdk/dartsdk-linux-x64-release.zip
    if command -v aria2c >/dev/null; then
      aria2c -x4 -s4 -o tool-dart.zip -d "$WORK" "$url"
    else
      curl -L --retry 3 -o "$zip" "$url"
    fi
    unzip -q -o "$zip" -d "$WORK/tool-dart-sdk"
  fi
}

# 应用 pubspec 固定 Flutter 3.47.5；检出提交在 tag 之后时 SDK 会自报 dev 版本，
# 需要把 version 与缓存元数据钉回 3.47.5，否则 pub 版本求解直接失败
ensure_flutter_version() {
  echo 3.47.5 > "$FLUTTER/version"
  git -C "$FLUTTER" tag -f 3.47.5 >/dev/null 2>&1 || true
  local json=$FLUTTER/bin/cache/flutter.version.json
  if [ -f "$json" ]; then
    python3 - "$json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
data["frameworkVersion"] = "3.47.5"
data["flutterVersion"] = "3.47.5"
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  fi
}

stage_tool() {
  log "准备 flutter 工具链（Dart 3.13.4 + 引擎自建 dartvm）"
  ensure_tool_dart
  local dartsdk=$WORK/tool-dart-sdk/dart-sdk

  # 引擎自建 dart-sdk 缺少 dartdev（pub），用官方 dart 处理 pub，其余交给 dartvm
  mkdir -p "$HOST_OUT/dart-sdk/bin/resources"
  cp -a "$dartsdk/bin/resources/devtools" "$HOST_OUT/dart-sdk/bin/resources/" 2>/dev/null || true
  cat > "$HOST_OUT/dart-sdk/bin/dart" <<EOF
#!/bin/bash
case "\$1" in
  pub) exec $dartsdk/bin/dart "\$@";;
esac
exec $HOST_OUT/dartvm "\$@"
EOF
  chmod +x "$HOST_OUT/dart-sdk/bin/dart"

  cd "$FLUTTER"
  ensure_flutter_version
  mkdir -p bin/cache
  rm -f bin/cache/flutter.version.json
  rm -rf bin/cache/dart-sdk
  ln -sfn "$HOST_OUT/dart-sdk" bin/cache/dart-sdk
  cp bin/internal/engine.version bin/cache/engine-dart-sdk.stamp
  rm -f bin/cache/flutter_tools.snapshot bin/cache/flutter_tools.stamp

  ( cd packages/flutter_tools && "$dartsdk/bin/dart" pub get )
  bin/cache/dart-sdk/bin/dart --verbosity=error \
    --snapshot=bin/cache/flutter_tools.snapshot --snapshot-kind=app-jit \
    --packages=packages/flutter_tools/.dart_tool/package_config.json \
    --no-enable-mirrors packages/flutter_tools/bin/flutter_tools.dart || true
  echo "$(git rev-parse HEAD):" > bin/cache/flutter_tools.stamp
  ./bin/flutter --version >/dev/null
}

stage_shell() {
  log "编译 Dart shell (libapp.so)"
  cd "$DENIAL_ROOT/dart_shell"
  "$FLUTTER/bin/flutter" pub get
  "$FLUTTER/bin/flutter" assemble \
    --local-engine-src-path="$VIEW" \
    --local-engine=denial_linux_loong64_release \
    --local-engine-host=denial_host_release \
    --suppress-analytics --resource-pool-size=10 \
    --output="$SHELL_OUT" \
    -dTargetFile=lib/main.dart -dBuildMode=release \
    -dTargetPlatform=linux-loong64 -dDartObfuscation=false \
    -dTrackWidgetCreation=true -dTreeShakeIcons=false \
    release_bundle_linux-loong64_assets
}

rust_cross_env() {
  # 单独运行 rust/apps 阶段时也要有交叉 pkg-config（不依赖先跑 env）
  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
  export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/lib/loongarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig
  export CC_loongarch64_unknown_linux_gnu="clang --target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CXX_loongarch64_unknown_linux_gnu="clang++ --target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export AR_loongarch64_unknown_linux_gnu=llvm-ar
  export CFLAGS_loongarch64_unknown_linux_gnu="--target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CXXFLAGS_loongarch64_unknown_linux_gnu="--target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CARGO_TARGET_LOONGARCH64_UNKNOWN_LINUX_GNU_LINKER=clang++
  # __tls_get_addr 仅由 ld-linux 提供，必须忽略目标文件中的未定义符号
  export CARGO_TARGET_LOONGARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=loongarch64-linux-gnu -C link-arg=--sysroot=$SYSROOT -C link-arg=-fuse-ld=lld -C link-arg=-L$SYSROOT/usr/lib -C link-arg=-L$SYSROOT/lib -C link-arg=-Wl,-rpath-link,$SYSROOT/usr/lib -C link-arg=-Wl,--unresolved-symbols=ignore-in-object-files"
  export CARGO_TARGET_DIR=$RUST_TARGET_DIR
}

stage_rust() {
  log "交叉编译 Rust compositor"
  rust_cross_env
  cd "$DENIAL_ROOT/compositor"
  cargo build --release --target "$TARGET_TRIPLE" --features flutter \
    --bin deniald --bin denialctl
  cargo build --release --target "$TARGET_TRIPLE" -p denial-portal
}

# 用与 stage_shell 相同的参数构建任意 Flutter 应用的 assets 与 libapp.so
assemble_flutter_app() {
  local app=$1 output=$2
  # 检出内 HEAD 与 stamp 不一致会让 flutter 包装脚本尝试联网 pub upgrade，
  # 这里直接用已有快照，避免离线/受限网络下卡住
  if [ -f "$FLUTTER/bin/cache/flutter_tools.snapshot" ]; then
    echo "$(git -C "$FLUTTER" rev-parse HEAD):" > "$FLUTTER/bin/cache/flutter_tools.stamp"
    ensure_flutter_version
  fi
  ( cd "$DENIAL_ROOT/$app" && \
    "$FLUTTER/bin/flutter" pub get >/dev/null && \
    "$FLUTTER/bin/flutter" assemble \
      --local-engine-src-path="$VIEW" \
      --local-engine=denial_linux_loong64_release \
      --local-engine-host=denial_host_release \
      --suppress-analytics --resource-pool-size=10 \
      --output="$output" \
      -dTargetFile=lib/main.dart -dBuildMode=release \
      -dTargetPlatform=linux-loong64 -dDartObfuscation=false \
      -dTrackWidgetCreation=true -dTreeShakeIcons=false \
      release_bundle_linux-loong64_assets )
}

# 组装 denial-app 运行的应用 bundle（polkit / 插件管理器）
compose_app_bundle() {
  local output=$1 assembly=$2 runner=$3
  rm -rf "$output"
  mkdir -p "$output/lib" "$output/data/flutter_assets"
  install -m755 "$RUST_TARGET_DIR/$TARGET_TRIPLE/release/denial-app" "$output/$runner"
  install -m755 "$assembly/lib/libapp.so" "$output/lib/"
  install -m755 "$TARGET_OUT/libflutter_engine.so" "$output/lib/"
  install -m644 "$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat" "$output/data/"
  cp -a "$assembly/flutter_assets/." "$output/data/flutter_assets/"
}

stage_apps() {
  log "编译独立应用（denial-app / polkit / 插件管理器）"
  rust_cross_env
  ( cd "$DENIAL_ROOT" && \
    cargo build --release --target "$TARGET_TRIPLE" --locked \
      --manifest-path native_app/Cargo.toml )
  # polkit 认证后端依赖 sysroot 中的 polkit 库；缺失时跳过（弹窗仍可构建）
  if pkg-config --exists polkit-agent-1 polkit-gobject-1; then
    ( cd "$DENIAL_ROOT/compositor" && \
      cargo build --release --target "$TARGET_TRIPLE" -p denial-polkit-agent )
  else
    log "sysroot 缺少 polkit-agent-1/polkit-gobject-1，跳过 denial-polkit-agent"
  fi

  mkdir -p "$APPS_OUT"
  assemble_flutter_app polkit_app "$APPS_OUT/polkit-assembly"
  compose_app_bundle "$APPS_OUT/polkit" "$APPS_OUT/polkit-assembly" denial-app
  assemble_flutter_app plugin_manager_app "$APPS_OUT/plugin-manager-assembly"
  compose_app_bundle "$APPS_OUT/plugin-manager" \
    "$APPS_OUT/plugin-manager-assembly" denial-plugin-manager
  # 插件管理器后端是 dart compile exe 交叉产物，需要 loong64 的 dartaotruntime；
  # 引擎当前不产出该运行时，因此这里只构建前端，后端缺失时由应用自身提示。
  file "$APPS_OUT/polkit/denial-app" "$APPS_OUT/plugin-manager/denial-plugin-manager"
}


stage_payload() {
  log "组装 payload"
  local rel=$RUST_TARGET_DIR/$TARGET_TRIPLE/release
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD/bin" "$PAYLOAD/bundle/lib" "$PAYLOAD/bundle/data/flutter_assets"
  install -m755 "$rel/deniald" "$rel/denialctl" "$rel/denial-portal" "$PAYLOAD/bin/"
  install -m755 "$TARGET_OUT/libflutter_engine.so" "$PAYLOAD/bundle/lib/"
  [ -f "$SHELL_OUT/lib/libapp.so" ] && install -m755 "$SHELL_OUT/lib/libapp.so" "$PAYLOAD/bundle/lib/"
  install -m644 "$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat" "$PAYLOAD/bundle/data/"
  cp -a "$SHELL_OUT/flutter_assets/." "$PAYLOAD/bundle/data/flutter_assets/"
  install -m644 "$DENIAL_ROOT/packaging/arch/outputs.conf" "$PAYLOAD/outputs.conf"
  [ -x "$TARGET_OUT/dartaotruntime" ] && \
    install -m755 "$TARGET_OUT/dartaotruntime" "$PAYLOAD/bin/"

  # 独立应用（缺阶段产物时跳过，保持 payload 可用）
  if [ -x "$rel/denial-app" ]; then
    install -m755 "$rel/denial-app" "$PAYLOAD/bin/"
    if [ -f "$APPS_OUT/polkit/denial-app" ]; then
      mkdir -p "$PAYLOAD/lib/denial"
      cp -a "$APPS_OUT/polkit" "$PAYLOAD/lib/denial/polkit"
      chmod -R u=rwX,go=rX "$PAYLOAD/lib/denial/polkit"
    fi
    [ -x "$rel/denial-polkit-agent" ] && install -m755 "$rel/denial-polkit-agent" "$PAYLOAD/bin/"
    if [ -f "$APPS_OUT/plugin-manager/denial-plugin-manager" ]; then
      cp -a "$APPS_OUT/plugin-manager" "$PAYLOAD/lib/denial/plugin-manager"
      chmod -R u=rwX,go=rX "$PAYLOAD/lib/denial/plugin-manager"
    fi
  fi
  ( cd "$PAYLOAD" && find bin bundle lib -type f -print0 2>/dev/null \
      | sort -z | xargs -0 sha256sum > SHA256SUMS )
  tar -C "$WORK" -czf "$WORK/denial-linux-loong64.tar.gz" payload
  file "$PAYLOAD"/bin/* "$PAYLOAD"/bundle/lib/*
  echo "归档: $WORK/denial-linux-loong64.tar.gz"
}

for s in "$@"; do
  case "$s" in
    env) stage_env ;;
    engine) stage_engine ;;
    tool) stage_tool ;;
    shell) stage_shell ;;
    rust) stage_rust ;;
    apps) stage_apps ;;
    payload) stage_payload ;;
    all)
      stage_env; stage_engine; stage_tool; stage_shell; stage_rust; \
        stage_apps; stage_payload ;;
    *) die "未知 stage: $s" ;;
  esac
done
