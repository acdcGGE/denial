#!/usr/bin/env bash
# denial v0.6.10 loongarch64 交叉编译脚本（在 x86-64 主机上编译出 loong64 产物）
#
# 用法:
#   ./contrib/loong64/build.sh <stage> [stage...]
#   stage: env | engine | tool | shell | rust | payload | all
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
  if ! git -C "$FLUTTER" apply --reverse --check \
      "$DENIAL_ROOT/contrib/loong64/flutter-denial-3.47.5-loongarch64.patch" >/dev/null 2>&1; then
    git -C "$FLUTTER" apply "$DENIAL_ROOT/contrib/loong64/flutter-denial-3.47.5-loongarch64.patch"
  fi
  mkdir -p "$FLUTTER/packages/flutter_tools"
  cp "$DENIAL_ROOT/contrib/loong64/flutter_tools-pubspec_overrides.yaml" \
     "$FLUTTER/packages/flutter_tools/pubspec_overrides.yaml"

  # host 编译所需的第三方头文件（Vulkan / ICU）来自 sysroot 与引擎源码
  mkdir -p "$WORK/host-deps/include"
  ln -sfn "$SYSROOT/usr/include/vulkan"   "$WORK/host-deps/include/vulkan"
  ln -sfn "$SYSROOT/usr/include/vk_video" "$WORK/host-deps/include/vk_video"
  ln -sfn "$ENGINE_SRC/flutter/third_party/icu/source/common/unicode" \
          "$WORK/host-deps/include/unicode"

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
      gen_snapshot flutter_patched_sdk \
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
  git tag -f 3.47.5 >/dev/null 2>&1 || true
  echo 3.47.5 > version
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

stage_rust() {
  log "交叉编译 Rust compositor"
  export CC_loongarch64_unknown_linux_gnu="clang --target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CXX_loongarch64_unknown_linux_gnu="clang++ --target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export AR_loongarch64_unknown_linux_gnu=llvm-ar
  export CFLAGS_loongarch64_unknown_linux_gnu="--target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CXXFLAGS_loongarch64_unknown_linux_gnu="--target=loongarch64-linux-gnu --sysroot=$SYSROOT"
  export CARGO_TARGET_LOONGARCH64_UNKNOWN_LINUX_GNU_LINKER=clang++
  # __tls_get_addr 仅由 ld-linux 提供，必须忽略目标文件中的未定义符号
  export CARGO_TARGET_LOONGARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=loongarch64-linux-gnu -C link-arg=--sysroot=$SYSROOT -C link-arg=-fuse-ld=lld -C link-arg=-L$SYSROOT/usr/lib -C link-arg=-L$SYSROOT/lib -C link-arg=-Wl,-rpath-link,$SYSROOT/usr/lib -C link-arg=-Wl,--unresolved-symbols=ignore-in-object-files"
  export CARGO_TARGET_DIR=$RUST_TARGET_DIR
  cd "$DENIAL_ROOT/compositor"
  cargo build --release --target "$TARGET_TRIPLE" --features flutter \
    --bin deniald --bin denialctl
  cargo build --release --target "$TARGET_TRIPLE" -p denial-portal
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
  ( cd "$PAYLOAD" && find bin bundle -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
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
    payload) stage_payload ;;
    all)
      stage_env; stage_engine; stage_tool; stage_shell; stage_rust; stage_payload ;;
    *) die "未知 stage: $s" ;;
  esac
done
