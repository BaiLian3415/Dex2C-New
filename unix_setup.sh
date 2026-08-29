#!/usr/bin/env bash
# ============================================================================
#  setup_dex2c_ollvm.sh —— Dex2C-New 一键环境部署脚本（依赖安装 + OLLVM 混淆工具链）
#
#  适用平台 : Ubuntu / Debian / Fedora / Arch / Rocky(x86_64)、Termux(aarch64)
#  放置位置 : 请放在 Dex2C-New 仓库根目录下（与 dcc.py / dcc.cfg 同级）
#
#  功能清单 :
#    [1] 安装系统依赖     : python3-pip / openjdk-17 / wget / unzip / 编译链等
#    [2] 安装 Python 依赖 : requirements.txt (networkx pydot future lxml ...)
#    [3] 定位 Android NDK : 命令行参数 > dcc.cfg > ~/android-sdk/ndk/* ，
#                           找不到时（仅 linux-x86_64）自动下载官方 r25c 兜底
#    [4] 获取 OLLVM 工具链，三种模式(--mode=)：
#         termux   : 直接下载 codehasan 预构建 OLLVM NDK（整包采用）
#         prebuilt : 使用 --ollvm-url 指定的预构建包
#                    （兼容「完整NDK打包」与「纯clang工具链打包」两种形式）
#         source   : 克隆 heroims/obfuscator（LLVM 13.x）并用 Ninja 现场编译
#         auto     : Termux 上走 termux 分支；PC 默认走 source
#    [5] 替换 NDK 的 clang : 首次自动备份为 *.orig；对齐 clang resource 目录，
#                            避免换芯后找不到 stddef.h 等内建头文件
#                            （兼容 Termux 整合版 NDK 内部目录带 linux-x86_64 标签的情况）
#    [6] 混淆能力自检      : 逐个 Pass 试编译（fla/bcf/sub 必须通过，sobf 仅提示）
#                            + 共享库链接 + 可执行文件运行冒烟测试
#    [7] 更新 dcc.cfg      : 写入 ndk_dir 与 ollvm.enable=true（--no-cfg-edit 关闭）
#
#  常用示例 :
#    bash setup_dex2c_ollvm.sh                          # 全自动部署(auto)
#    bash setup_dex2c_ollvm.sh --dry-run                # 只打印计划动作，不落地
#    bash setup_dex2c_ollvm.sh --mode=source            # 强制源码编译 OLLVM
#    bash setup_dex2c_ollvm.sh --mode=prebuilt --ollvm-url=/x/ollvm.tar.gz
#    bash setup_dex2c_ollvm.sh --ndk-dir=/opt/android-ndk-r25c
#    bash setup_dex2c_ollvm.sh --skip-system-deps       # 跳过系统包管理器安装
#    JOBS=8 bash setup_dex2c_ollvm.sh --mode=source     # 指定编译并行数
#
#  回滚方式 : 还原 NDK 目录下的 bin/clang.orig → bin/clang 即可恢复原版工具链
# ============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- 颜色与日志
if [ -t 1 ]; then C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_C=$'\033[36m'; C_N=$'\033[0m'
else C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_N=""; fi
info(){ printf '%s\n' "${C_B}[INFO ]${C_N} $*"; }
ok(){   printf '%s\n' "${C_G}[ OK  ]${C_N} $*"; }
warn(){ printf '%s\n' "${C_Y}[WARN ]${C_N} $*"; }
err(){  printf '%s\n' "${C_R}[ERROR]${C_N} $*" >&2; }
die(){  err "$*"; exit 1; }
step(){ printf '\n%s\n' "${C_C}━━━━ $* ━━━━${C_N}"; }

# ---------------------------------------------------------------- 全局默认值
SCRIPT_PATH="${BASH_SOURCE[0]}"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # 脚本所在目录 = 仓库根
WORK_DIR="$REPO_DIR/.ollvm-work"                       # 下载/编译工作区（可整体删除）
DRYRUN=0; MODE="auto"; CFG_EDIT=1
DO_SYS=1; DO_PY=1; JOBS=""
NDK_IN=""; OLLVM_URL=""
NDK_REL="r25c"        # 官方兜底下载版本：与 OLLVM(LLVM13) 配对兼容性最佳
TERMUX_URL="https://github.com/codehasan/dex2c/releases/download/ollvm-termux/android-ndk-r25c-ollvm-aarch64.tar.xz"

while [ $# -gt 0 ]; do
  case "$1" in
    --ndk-dir=*)        NDK_IN="${1#*=}" ;;
    --ollvm-url=*)      OLLVM_URL="${1#*=}" ;;
    --mode=*)           MODE="${1#*=}" ;;       # auto|termux|prebuilt|source
    --jobs=*)           JOBS="${1#*=}" ;;
    --skip-system-deps) DO_SYS=0 ;;
    --skip-python-deps) DO_PY=0 ;;
    --no-cfg-edit)      CFG_EDIT=0 ;;
    --dry-run)          DRYRUN=1 ;;
    -h|--help)          sed -n '2,45p' "$SCRIPT_PATH"; exit 0 ;;
    *) die "未知参数: $1 （使用 -h 查看帮助）" ;;
  esac
  shift
done

# 干跑模式：一切“会产生副作用”的命令一律只打印不执行
run(){
  if [ "$DRYRUN" = "1" ]; then info "[dry-run] $*"; else "$@"; fi
}

mkdir -p "$WORK_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 平台探测
IS_TERMUX=0
case "${PREFIX:-}" in *com.termux*) IS_TERMUX=1 ;; esac
OS_UNAME="$(uname -s)"; ARCH="$(uname -m)"
case "$OS_UNAME-$ARCH" in
  Linux-x86_64)              HOST_TAG="linux-x86_64"  ;;
  Linux-aarch64|Linux-arm64) HOST_TAG="linux-aarch64" ;;
  Darwin-*)                  HOST_TAG="darwin-x86_64" ;;
  *)                         HOST_TAG="linux-x86_64"  ;;
esac
info "平台检测: $(uname -sro) | 架构=$ARCH | HostTag=$HOST_TAG | Termux=$([ "$IS_TERMUX" = "1" ] && echo yes || echo no)"

ROOT=""
if [ "$(id -u)" = "0" ]; then ROOT=""
elif command -v sudo >/dev/null 2>&1; then ROOT="sudo"
else warn "当前无 root 且无 sudo，系统级安装可能失败"; ROOT=""; fi

# 注意：Termux 同时存在 apt-get 与 pkg，但二者源不同，
# 必须优先判定 Termux，否则会误走桌面发行版分支！
pick_pm(){
  PM=""
  if [ "$IS_TERMUX" = "1" ];             then PM="pkg"
  elif command -v apt-get >/dev/null 2>&1; then PM="apt-get"
  elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
  elif command -v yum     >/dev/null 2>&1; then PM="yum"
  elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
  fi
}
APT_UPDATED=0
pkg_install(){
  pick_pm
  [ -n "$PM" ] || die "未识别的包管理器，请手动安装: $*"
  case "$PM" in
    apt-get)
      if [ "$APT_UPDATED" = "0" ]; then run $ROOT apt-get update -y || true; APT_UPDATED=1; fi
      run $ROOT env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf|yum) run $ROOT "$PM" install -y "$@" ;;
    pacman)  run $ROOT pacman -S --needed --noconfirm "$@" ;;
    pkg)     run pkg install -y "$@" ;;
  esac
}
try_install_any(){   # 依次尝试多个候选包名，直到某个可用为止
  for p in "$@"; do
    if pkg_install "$p"; then return 0; fi
  done
  warn "以下候选包均未装成功（可能已存在或名字不同）: $*"
}

# ---- 模式前置解析：提前到依赖安装阶段之前，
#      这样源码编译模式所需的 cmake/ninja/工具链 能一并纳入自动安装清单
if [ "$MODE" = "auto" ]; then
  if [ "$IS_TERMUX" = "1" ]; then MODE="termux"; else MODE="source"; fi
  info "auto 模式判定 → 采用 $MODE"
fi

# ============================================================ STEP 1. 系统依赖
step "STEP 1/6  安装系统依赖"
BASE_PKGS_OK=1
for c in python3 git wget curl unzip xz file; do
  command -v "$c" >/dev/null 2>&1 || BASE_PKGS_OK=0
done
JAVA_OK=0
if command -v java >/dev/null 2>&1; then
  jv="$(java -version 2>&1 | head -n1 | sed -E 's/.*version "?([0-9]+).*/\1/')"
  case "${jv:-x}" in *[!0-9]*|"") jv=0 ;; esac
  [ "$jv" -ge 17 ] 2>/dev/null && JAVA_OK=1 || true
fi

if [ "$DO_SYS" = "1" ]; then
  if [ "$IS_TERMUX" = "1" ]; then
    info "Termux 环境 —— 按 termux_setup.sh 同款清单安装 ..."
    run pkg update -y || true
    pkg_install ncurses-utils python git wget unzip xz-utils binutils file \
                make cmake ninja zlib openssl libxml2 libxslt \
                libjpeg-turbo pkg-config || true
    try_install_any openjdk-17 || true
    run pkg install -y build-essential || true
  else
    ml=""
    if [ "$BASE_PKGS_OK" = "0" ]; then ml="python3 python3-pip git wget unzip xz-utils file"; fi
    if [ "$JAVA_OK" != "1" ]; then
      pick_pm
      case "$PM" in
        dnf|yum) ml="$ml java-17-openjdk-headless" ;;
        pacman)  ml="$ml jre17-openjdk-headless"   ;;
        *)       ml="$ml openjdk-17-jre-headless"  ;;
      esac
    fi
    # 源码编译 OLLVM 需要完整宿主工具链，一并检查安装
    if [ "$MODE" = "source" ]; then
      pick_pm
      case "$PM" in
        dnf|yum) ml="$ml gcc gcc-c++ make cmake ninja-build zlib-devel" ;;
        pacman)  ml="$ml base-devel cmake ninja zlib"                   ;;
        *)       ml="$ml build-essential cmake ninja-build zlib1g-dev"  ;;
      esac
    fi
    if [ "$(echo $ml | wc -w)" -gt 0 ]; then
      info "安装缺失的基础组件: $ml"
      pkg_install $ml
    else
      ok "基础系统组件齐全"
    fi
  fi
  command -v java    >/dev/null 2>&1 || warn "缺少 java —— apktool/apksigner 运行必需！请自行安装 JDK 17+"
  command -v python3 >/dev/null 2>&1 || die "python3 缺失且自动安装失败，请手动安装后重跑"
else
  info "--skip-system-deps 已指定，跳过系统包安装"
fi
ok "系统依赖阶段完成"

# ========================================================== STEP 2. Python 依赖
step "STEP 2/6  安装 Python 依赖 (requirements.txt)"
cd "$REPO_DIR"
[ -f requirements.txt ] || die "未找到 requirements.txt —— 请把本脚本放到仓库根目录后运行！"
PIP="python3 -m pip"
run $PIP install --upgrade pip setuptools wheel
if [ "$IS_TERMUX" = "1" ]; then
  info "Termux: lxml/cryptography 常需源码编译，套用官方脚本推荐参数 ..."
  if [ "$DRYRUN" = "1" ]; then
    run $PIP install --upgrade lxml cryptography pillow cython
  else
    LDFLAGS="-L${PREFIX}/lib/" \
    CFLAGS="-I${PREFIX}/include/ -Wno-error=incompatible-function-pointer-types -O0" \
      $PIP install --upgrade lxml cryptography pillow cython
  fi
fi
run $PIP install -r "$REPO_DIR/requirements.txt"
ok "Python 依赖已就绪（networkx / pydot / future / pyasn1 / cryptography / lxml / asn1crypto）"

# ======================================================== STEP 3. 定位 NDK
step "STEP 3/6  定位 Android NDK"
# NDK 内部目录标签探测：官方包固定为 linux-x86_64 / darwin-x86_64，
# 而 Termux 移植的整合版虽跑在 aarch64 上，内部目录仍叫 linux-x86_64，
# 因此这里用「逐个候选探测」而不是简单套用宿主架构标签。
ndk_prebuilt_dir(){   # $1=NDK根目录，成功则打印其内部 prebuilt 路径
  for t in linux-x86_64 linux-aarch64 darwin-x86_64 "$HOST_TAG"; do
    if [ -d "$1/toolchains/llvm/prebuilt/$t/bin" ]; then
      printf '%s' "$1/toolchains/llvm/prebuilt/$t"
      return 0
    fi
  done
  return 1
}
ndk_valid(){ ndk_prebuilt_dir "$1" >/dev/null; }

find_ndk(){
  # 1) 显式指定
  if [ -n "$NDK_IN" ]; then
    ndk_valid "$NDK_IN" || die "--ndk-dir=$NDK_IN 不是合法 NDK（缺 toolchains/llvm/prebuilt/*/bin）"
    NDK_DIR="$(cd "$NDK_IN" && pwd)"
    return 0
  fi
  # 2) dcc.cfg
  if [ -f dcc.cfg ] && [ -s dcc.cfg ]; then
    cfg_ndk="$(python3 - <<'PYCFG'
import json
try:
    v=json.load(open("dcc.cfg")).get("ndk_dir","")
    print(v if isinstance(v,str) else "")
except Exception:
    pass
PYCFG
)" || cfg_ndk=""
    if [ -n "$cfg_ndk" ] && ndk_valid "$cfg_ndk"; then
      NDK_DIR="$(cd "$cfg_ndk" && pwd)"
      return 0
    fi
  fi
  # 3) 扫描常见 SDK 目录（取版本号最大者）
  cand=""
  for base in "$HOME/android-sdk/ndk" "$HOME/Library/Android/sdk/ndk" "/opt/android-sdk/ndk"; do
    [ -d "$base" ] || continue
    hit="$(ls -1d "$base"/*/ 2>/dev/null | while read -r d; do
            if ndk_valid "${d%/}"; then printf '%s\n' "${d%/}"; fi
          done | sort -V | tail -n1)"
    if [ -n "$hit" ]; then cand="$hit"; break; fi
  done
  if [ -n "$cand" ]; then NDK_DIR="$cand"; return 0; fi
  return 1
}

if find_ndk; then
  ok "已定位现有 NDK: $NDK_DIR"
else
  if [ "$OS_UNAME" = "Linux" ] && [ "$ARCH" = "x86_64" ]; then
    dl_url="https://dl.google.com/android/repository/android-ndk-${NDK_REL}-linux.zip"
    dest="$HOME/android-sdk/ndk"
    info "未找到已有 NDK，将自动下载官方 ${NDK_REL}（约700MB）到 $dest"
    run mkdir -p "$dest"
    run wget -q --show-progress "$dl_url" -O "$WORK_DIR/ndk.zip"
    if [ "$DRYRUN" = "0" ]; then
      unzip -q "$WORK_DIR/ndk.zip" -d "$WORK_DIR"
      mv "$WORK_DIR/android-ndk-$NDK_REL" "$dest/"
      rm -f "$WORK_DIR/ndk.zip"
    else
      run sh -c "unzip ndk.zip 并移动 android-ndk-$NDK_REL → $dest/"
    fi
    if [ "$DRYRUN" = "1" ]; then
      NDK_DIR="$dest/android-ndk-$NDK_REL"
      ok "[dry-run] 计划采用的 NDK 路径: $NDK_DIR （真实运行时自动下载解压到此处）"
    else
      find_ndk || die "NDK 下载后仍无法定位，请改用 --ndk-dir=<路径> 手动指定"
      ok "官方 NDK 就绪: $NDK_DIR"
    fi
  elif [ "$IS_TERMUX" = "1" ]; then
    info "Termux 未检测到 NDK —— 将在下一步直接采用 OLLVM 整合版 NDK"
    NDK_DIR=""
  else
    die "未能定位 NDK，请先安装 Android NDK 或用 --ndk-dir=<路径> 指定"
  fi
fi

# ==================================================== STEP 4. 获取 OLLVM 工具链
step "STEP 4/6  获取 OLLVM 工具链 (mode=$MODE)"

resolve_pkg(){   # 解析解包后的目录结构，设置全局 SRC_BIN / SRC_RES / STAGE_NDK
  stage="$1"
  STAGE_NDK=""
  probe_base="$stage"
  sd="$(ls -1d "$stage"/android-ndk-* 2>/dev/null | head -n1 || true)"
  [ -n "$sd" ] && probe_base="$sd"
  pb=""
  for t in linux-x86_64 linux-aarch64 darwin-x86_64 "$HOST_TAG"; do
    if [ -d "$probe_base/toolchains/llvm/prebuilt/$t/bin" ]; then pb="$probe_base/toolchains/llvm/prebuilt/$t"; break; fi
  done
  if [ -n "$pb" ]; then
    STAGE_NDK="$probe_base"
    SRC_BIN="$pb/bin"
    SRC_RES="$(ls -1d "$pb/lib/clang"/[0-9]* 2>/dev/null | head -n1 || true)"
    return 0
  fi
  fc="$(find "$stage" -maxdepth 4 \( -type f -o -type l \) \( -name clang -o -name clang.exe \) 2>/dev/null | head -n1 || true)"
  if [ -n "$fc" ]; then
    lb="$(dirname "$fc")"
    ll="$(ls -1d "$lb/../lib/clang"/[0-9]* 2>/dev/null | head -n1 || true)"
    if [ -n "$ll" ]; then
      SRC_BIN="$lb"; SRC_RES="$ll"; STAGE_NDK=""
      return 0
    fi
    die "该预构建包含 clang 但缺少配套 lib/clang/<ver> 资源目录，无法安全集成"
  fi
  die "无法从压缩包中识别出「完整NDK」或「纯clang工具链」结构"
}

SRC_BIN=""; SRC_RES=""; STAGE_NDK=""
case "$MODE" in
  termux)
    if [ "$IS_TERMUX" != "1" ]; then warn "非 Termux 环境却选择了 termux 模式，继续尝试（通常仅适用于 aarch64 Linux）"; fi
    info "下载预构建 OLLVM NDK 整合包 ..."
    run wget -q --show-progress "$TERMUX_URL" -O "$WORK_DIR/ollvm-ndk.tar.xz"
    if [ "$DRYRUN" = "0" ]; then
      tar -xf "$WORK_DIR/ollvm-ndk.tar.xz" -C "$WORK_DIR"
      resolve_pkg "$WORK_DIR"
    else
      SRC_BIN="<tar包内clang>"; SRC_RES="<内置资源目录>"; STAGE_NDK="<完整OLLVM NDK>"
    fi
    ;;
  prebuilt)
    [ -n "$OLLVM_URL" ] || die "prebuilt 模式必须提供 --ollvm-url=<URL 或本地压缩包路径>"
    info "获取自定义 OLLVM 包: $OLLVM_URL"
    local_file="$OLLVM_URL"
    case "$OLLVM_URL" in
      http://*|https://*)
        local_file="$WORK_DIR/ollvm.pkg"
        run wget -q --show-progress "$OLLVM_URL" -O "$local_file" ;;
    esac
    if [ "$DRYRUN" = "0" ]; then
      exdir="$WORK_DIR/pkg.$$"; mkdir -p "$exdir"
      case "$local_file" in
        *.zip)                unzip -q "$local_file" -d "$exdir" ;;
        *.tar.xz|*.txz)       tar -xJf "$local_file" -C "$exdir" ;;
        *.tar.gz|*.tgz)       tar -xzf "$local_file" -C "$exdir" ;;
        *.7z)
          if ! command -v 7z >/dev/null 2>&1; then
            try_install_any p7zip-full p7zip 7zip
          fi
          7z x -y -o"$exdir" "$local_file" >/dev/null ;;
        *) die "不支持的格式: $local_file （支持 zip / tar.xz / tar.gz / 7z）" ;;
      esac
      resolve_pkg "$exdir"
    else
      SRC_BIN="<url包内clang>"; SRC_RES="<url包内资源>"; STAGE_NDK="<完整NDK 或 工具链包>"
    fi
    ;;
  source)
    info "源码编译模式 —— 基于 heroims/obfuscator（LLVM 13.x）"
    avail_gb="$(df -BG "$WORK_DIR" 2>/dev/null | awk 'NR==2{gsub("G","",$4);print $4}')"
    case "${avail_gb:-0}" in *[!0-9]*|"") avail_gb=0 ;; esac
    if [ "$avail_gb" -lt 40 ] 2>/dev/null; then warn "工作区剩余空间约 ${avail_gb}GB —— 源码编译建议 ≥40GB，有爆盘风险！"; fi
    warn "预计资源消耗: 内存≥8~16GB、时长 30~90 分钟（视 CPU 与并行数而定），期间请勿休眠"
    if [ ! -d "$WORK_DIR/llvm-src" ]; then
      run git clone --depth 1 -b llvm-13.x https://github.com/heroims/obfuscator.git "$WORK_DIR/llvm-src" \
        || run git clone --depth 1 https://github.com/heroims/obfuscator.git "$WORK_DIR/llvm-src"
    fi
    if [ "$DRYRUN" = "1" ]; then
      command -v cmake >/dev/null 2>&1 || warn "[dry-run] 当前环境缺 cmake —— 真实运行时已由 STEP1 纳入自动安装计划"
    else
      command -v cmake >/dev/null 2>&1 || die "缺少 cmake，请先执行系统依赖安装（去掉 --skip-system-deps 重试）"
    fi
    command -v ninja >/dev/null 2>&1 || { command -v cmake >/dev/null 2>&1 && warn "未找到独立 ninja 命令，将尝试让 cmake 选择其它生成器"; }
    LD_OK=""
    for ld in lld gold mold bfd; do
      command -v "ld.$ld" >/dev/null 2>&1 && LD_OK="$ld" && break || true
    done
    if [ -z "$JOBS" ]; then JOBS="$(nproc 2>/dev/null || echo 4)"; fi
    info "并行任务数: $JOBS  链接器优先级选择: ${LD_OK:-默认bfd}"
    LINKER_OPT=()
    if [ -n "$LD_OK" ]; then LINKER_OPT=(-DLLVM_USE_LINKER="$LD_OK"); fi

    # ---- 新版 GCC 兼容性自动规避 ----
    # GCC 13+ 收紧了标准库头文件的传递包含，而 LLVM 13 源码依赖这些传递包含，
    # 会报 'uint64_t' was not declared in this scope（提示加 #include <cstdint>）。
    # 规避策略（按优先级）：
    #   ① 探测到更低版本 g++(12/11/10) 则直接切换编译器 —— 最干净可靠
    #   ② 找不到则给每个翻译单元预注入缺失头文件:
    #      -DCMAKE_CXX_FLAGS="-include cstdint -include cstring"
    COMPILER_OPT=(); CXX_COMPAT_FLAGS=""
    if [ "$OS_UNAME" = "Linux" ]; then
      host_gcc_major="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
      case "${host_gcc_major:-x}" in *[!0-9]*|"") host_gcc_major=0 ;; esac
      if [ "$host_gcc_major" -ge 13 ] 2>/dev/null; then
        warn "宿主 GCC=$host_gcc_major 与 LLVM 13 存在已知头文件兼容冲突，自动规避..."
        LOW_GXX=""
        for cg in g++-12 g++-11 g++-10; do
          command -v "$cg" >/dev/null 2>&1 && { LOW_GXX="$cg"; break; } || true
        done
        if [ -z "$LOW_GXX" ] && [ "$DRYRUN" = "0" ]; then
          info "尝试安装低版本编译器 g++-12 ..."
          try_install_any g++-12 || true
          command -v g++-12 >/dev/null 2>&1 && LOW_GXX="g++-12" || true
        fi
        if [ -n "$LOW_GXX" ]; then
          ok "构建编译器切换为 $LOW_GXX （配套 gcc-${LOW_GXX##*-}）"
          COMPILER_OPT=(-DCMAKE_C_COMPILER="gcc-${LOW_GXX##*-}" -DCMAKE_CXX_COMPILER="$LOW_GXX")
        else
          warn "无低版本 g++ 可用 → 采用预包含头文件兼容方案 (-include cstdint/cstring)"
          CXX_COMPAT_FLAGS="-include cstdint -include cstring"
        fi
      fi
    fi
    GEN=Ninja
    command -v ninja >/dev/null 2>&1 || GEN="Unix Makefiles"
    run cmake -G "$GEN" -S "$WORK_DIR/llvm-src/llvm" -B "$WORK_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS=clang \
        -DLLVM_TARGETS_TO_BUILD="X86;ARM;AArch64" \
        -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_BINDINGS=OFF \
        -DCMAKE_CXX_FLAGS="$CXX_COMPAT_FLAGS" \
        "${COMPILER_OPT[@]}" \
        "${LINKER_OPT[@]}"
    # ---- 配置后防呆校验：确认 clang 项目真的被启用 ----
    # （防止因手动改参/异常中断导致生成「无 clang 目标」的纯 LLVM 构建树）
    # 注意：必须锚定 "LLVM_ENABLE_PROJECTS:" 带类型后缀的形式，
    # 否则会误匹配到内部变量 LLVM_ENABLE_PROJECTS_USED:BOOL=1 造成误报
    if [ "$DRYRUN" = "0" ]; then
      cc_proj="$(sed -n 's/^LLVM_ENABLE_PROJECTS:[^=]*=//p' "$WORK_DIR/build/CMakeCache.txt" 2>/dev/null | tail -n1 || true)"
      ninja_has_clang=0
      if [ -f "$WORK_DIR/build/build.ninja" ] && grep -qE "^build bin/clang(\+\+)?: " "$WORK_DIR/build/build.ninja" 2>/dev/null; then
        ninja_has_clang=1
      fi
      case "$cc_proj" in
        *clang*)
          ok "configure 校验通过：启用项目 = $cc_proj${ninja_has_clang:+（且 build.ninja 含 clang 构建目标）}" ;;
        "")
          if [ "$ninja_has_clang" = "1" ]; then
            ok "configure 校验通过：build.ninja 中存在 bin/clang 构建目标"
          else
            warn "无法读取 LLVM_ENABLE_PROJECTS 且未发现 clang 构建目标 —— 将由编译步骤做最终判定"
          fi ;;
        *)
          if [ "$ninja_has_clang" = "1" ]; then
            ok "CMakeCache 变量解析歧义，但 build.ninja 存在 bin/clang 构建目标，视为配置正常"
          else
            die "configure 异常：未包含 clang 项目（实际值='$cc_proj'）—— 请勿手工改动脚本的 cmake 参数，删除 $WORK_DIR/build 后重跑"
          fi ;;
      esac
    else
      info "[dry-run] 配置完成后将校验 CMakeCache：LLVM_ENABLE_PROJECTS 必须包含 clang"
    fi
    # 注意：LLVM 构建系统中不存在名为 clang++ 的 ninja target，
    # clang++ 只是 clang 的符号链接（仅 install 阶段才生成），
    # 这里只能构建 clang，否则 ninja 直接报 unknown target
    run cmake --build "$WORK_DIR/build" -j "$JOBS" --target clang
    if [ "$DRYRUN" = "0" ]; then
      [ -x "$WORK_DIR/build/bin/clang" ] || die "编译产物缺少 build/bin/clang，请检查上方构建日志"
      # build/bin 默认不生成 clang++（仅 install 阶段创建），补上符号链接保持一致性
      if [ ! -e "$WORK_DIR/build/bin/clang++" ]; then
        ln -sfn clang "$WORK_DIR/build/bin/clang++"
      fi
      SRC_BIN="$WORK_DIR/build/bin"
      SRC_RES="$(ls -1d "$WORK_DIR/build/lib/clang"/[0-9]* 2>/dev/null | head -n1 || true)"
      [ -n "$SRC_RES" ] || die "未找到编译输出的 resource 目录（build/lib/clang/<ver>）"
    else
      SRC_BIN="<build/bin>"; SRC_RES="<build/lib/clang/13.0.x>"
    fi
    ok "OLLVM 工具链就绪: $SRC_BIN"
    ;;
  *)
    die "未知 mode: $MODE （可选 auto|termux|prebuilt|source）" ;;
esac

# ------------------------------------- Termux 整包特殊分支：直接采用新 NDK
SKIP_REPLACE=0
if [ "$MODE" = "termux" ]; then
  target_root="$HOME/android-sdk/ndk"
  final="$target_root/android-ndk-r25c-ollvm"
  run mkdir -p "$target_root"
  run rm -rf "$final"
  if [ "$DRYRUN" = "0" ]; then
    if [ ! -d "$STAGE_NDK" ]; then die "termux 模式解析失败：未获得完整 NDK 目录"; fi
    mv "$STAGE_NDK" "$final"
    ndk_valid "$final" || die "OLLVM NDK 目录结构异常: $final"
    # mv 后旧 SRC_BIN/SRC_RES 已失效，必须基于新位置重新指认
    newpb="$(ndk_prebuilt_dir "$final")"
    SRC_BIN="$newpb/bin"
    SRC_RES="$(ls -1d "$newpb/lib/clang"/[0-9]* 2>/dev/null | head -n1 || true)"
    NDK_DIR="$final"
  else
    NDK_DIR="$final"
    run sh -c "mv 解压出的NDK → $final"
  fi
  ok "采用整合版 OLLVM NDK: $NDK_DIR （后续对本 NDK 执行全量校验）"
  SKIP_REPLACE=1
fi

# ================================================== STEP 5. 替换 clang + 自检
step "STEP 5/6  接入 OLLVM clang 到目标 NDK 并自检"

# 在 dry-run 下自检仅打印计划；真实运行时逐 Pass 编译验证。
SELFTEST_DRY_PLANNED=0
text_size(){   # 某目标文件的 .text 段字节数（无则回显 0）
  "$TB/llvm-size" -A "$1" 2>/dev/null | awk '\$1==".text"{print \$2}' | grep . || echo 0
}
check_pass(){   # $1=描述  $2=是否可选(optional)  其余=flags(可为多词字符串)
  desc="$1"; optional="${2:-required}"; shift 2
  flags="$*"
  if [ "$DRYRUN" = "0" ]; then
    clog="$TV/pass.log"
    # 差分检测：clang13 默认 New PM 会静默忽略 legacy 注册的混淆 Pass
    # （参数可解析、退出码 0，但代码零变换）。必须对比“带/不带 flags”
    # 的 .text 体积，防止此类假绿。
    "$TB/clang" -O1 "$TV/t.c" -c -o "$TV/base.o" 2>>"$clog" || true
    base_sz="$(text_size "$TV/base.o")"
    if "$TB/clang" -O1 $flags "$TV/t.c" -c -o "$TV/out.o" 2>"$clog"; then
      out_sz="$(text_size "$TV/out.o")"
      grew=0
      [ "${out_sz:-0}" -gt "$((base_sz * 2))" ] 2>/dev/null && grew=1
      if [ "$grew" = "1" ]; then
        ok "Pass[$desc] ✓ 生效确认 .text ${base_sz}B→${out_sz}B ($flags)"
        return 0
      fi
      err "Pass[$desc] ✗ 参数可解析但代码零变换（.text ${base_sz}B→${out_sz}B）——多为 New PM 静默忽略 legacy Pass"
      err "  补救: 在 dcc.cfg 的 ollvm.flags 最前面加 -flegacy-pass-manager 后重跑本脚本"
      CORE_FAIL=1
    fi
    if [ "$optional" = "optional" ]; then
      warn "Pass[$desc] 不受支持 —— 仅影响该项能力，其余 Pass 可正常使用 ($(tail -n2 "$clog" | tr '\n' ' '))"
    else
      err "Pass[$desc] ✗ 该 clang 不支持必备混淆 Pass！($(tail -n2 "$clog" | tr '\n' ' '))"
      CORE_FAIL=1
    fi
  else
    SELFTEST_DRY_PLANNED=$((SELFTEST_DRY_PLANNED+1))
    run sh -c "clang -O1 t.c -c && clang -O1 $flags t.c -c ; 对比 .text 体积   # <- Pass[$desc]"
  fi
  return 0
}

replace_clang(){   # $1=目标NDK根目录
  if ! pb="$(ndk_prebuilt_dir "$1")"; then
    if [ "$DRYRUN" = "1" ]; then
      warn "dry-run：目标 NDK 尚未真实落盘，以下为将执行的动作演示 ——"
      run cp -a bin/clang → bin/clang.orig（首次备份，幂等）
      run sh -c "写入 OLLVM clang/clang++，并把配套 lib/clang/<版本> 拷入（或建兼容符号链接）"
      SELFTEST_DRY_PLANNED=$((SELFTEST_DRY_PLANNED+4))
      run sh -c "自检: fla/bcf/sub 必备Pass编译 + sobf可选探针 + .so 链接 + 可执行文件运行冒烟"
      return 0
    fi
    die "NDK 结构异常（找不到 toolchains/llvm/prebuilt/*/bin）: $1"
  fi
  TARGET_TAG="$(basename "$(dirname "$pb")")"
  tb="$pb/bin"; tl="$pb/lib/clang"
  TB="$tb"; TL="$tl"
  [ -d "$tb" ] || die "目标 NDK 缺少 bin 目录: $tb"

  # ---- 备份原件（只保留第一次的原版备份，避免二次运行覆盖真原版）----
  if [ "$DRYRUN" = "0" ]; then
    [ -e "$tb/clang.orig" ] || cp -a "$tb/clang" "$tb/clang.orig"
    if [ -e "$tb/clang++.orig" ]; then :
    elif [ -e "$tb/clang++" ]; then cp -aL "$tb/clang++" "$tb/clang++.orig" 2>/dev/null || true
    fi
  else
    run cp -a "bin/clang → bin/clang.orig（首次备份，之后幂等）"
  fi
  info "备份策略: 已存在 *.orig 则不再覆盖（还原时用它即可回到官方工具链）"

  # ---- 写入新二进制（覆盖被保护文件前再次确认存在 src）----
  if [ "$DRYRUN" = "0" ]; then
    [ -f "$SRC_BIN/clang" ] || die "源目录缺少 clang 二进制: $SRC_BIN"
    cat "$SRC_BIN/clang" > "$tb/clang.tmp.$$" && chmod 755 "$tb/clang.tmp.$$" \
      && mv -f "$tb/clang.tmp.$$" "$tb/clang"
    if [ -e "$SRC_BIN/clang++" ] && [ ! -L "$SRC_BIN/clang++" ]; then
      cat "$SRC_BIN/clang++" > "$tb/clang++.tmp.$$" && chmod 755 "$tb/clang++.tmp.$$" \
        && mv -f "$tb/clang++.tmp.$$" "$tb/clang++"
    else
      ln -sfn clang "$tb/clang++"
    fi
  else
    run sh -c "install \$SRC_BIN/clang → $tb/clang ; clang++ 由二进制或软链提供"
  fi
  nv=""
  if [ "$DRYRUN" = "0" ]; then nv="$("$tb/clang" --version 2>/dev/null | head -n1 || true)"; fi
  info "新 clang 版本行: ${nv:-<待自检步骤输出>}"

  # ---- 对齐 resource 目录（否则 stddef.h / stdarg.h 会“失踪”）----
  if [ "$DRYRUN" = "0" ]; then
    want_res="$("$tb/clang" -print-resource-dir 2>/dev/null || true)"
    want_name="$(basename "$want_res" 2>/dev/null || true)"
    if [ -n "$want_res" ] && [ -d "$want_res" ]; then
      ok "resource 目录天然配套: $want_res"
    elif [ -n "$SRC_RES" ] && [ -d "$SRC_RES" ] && [ -n "$want_name" ]; then
      mkdir -p "$tl"
      cp -a "$SRC_RES" "$tl/" 
      if [ "$SRC_RES" != "$tl/$want_name" ] && [ ! -e "$tl/$want_name" ]; then
        mv "$tl/$(basename "$SRC_RES")" "$tl/$want_name"
      fi
      ok "已拷贝配套 resource 目录 → $tl/$want_name"
    else
      fb="$(ls -1d "$tl"/[0-9]* 2>/dev/null | sort -V | tail -n1 || true)"
      if [ -n "$fb" ]; then
        ln -sfn "$(basename "$fb")" "$tl/$want_name"
        warn "暂借既有 resource 目录顶替（可能存在轻微头文件差异）: $(basename "$fb") → $want_name"
      else
        die "无法准备 clang resource 目录，编译将无法启动（lib/clang 为空）"
      fi
    fi
  else
    run sh -c "对齐 clang resource 目录: 拷贝 \$SRC_RES → lib/clang/<新版本号> （或建兼容符号链接）"
  fi

  # ---- 运行时静态库桥接：防止 unwind/builtins “失踪” ----
  # 换芯后的 OLLVM clang 其资源目录通常只含头文件；而 ndk-build 会按
  # 「当前 clang」的 -print-resource-dir 推导 NDK_TOOLCHAIN_LIB_DIR，
  # 并要求 <resource>/lib/linux/<abi>/libunwind.a 物理存在
  # （sources/cxx-stl/llvm-libc++abi/Android.mk 定义同名 prebuilt 模块）。
  if [ "$DRYRUN" = "0" ]; then
    res_dir="$tl/$want_name"
    if ! ls "$res_dir"/lib/linux/*/libunwind.a >/dev/null 2>&1; then
      donor="$(ls -1d "$pb"/lib*/clang/*/ 2>/dev/null | sort -V | while read -r d; do
                [ "${d%/}" != "$res_dir" ] && [ -d "${d%/}/lib/linux" ] \
                  && printf '%s\n' "${d%/}" || true
              done | tail -n1)"
      if [ -n "$donor" ]; then
        info "迁移官方运行时库: ${donor}/lib → ${res_dir}/ （链接期 unwind/builtins 所需）"
        cp -a "${donor%/}/lib" "$res_dir/"
      else
        warn "未找到可借用的完整资源目录 —— 链接期可能缺 libunwind.a！"
        warn "补救: 将一份未动过的官方同版 NDK 中 toolchains/llvm/prebuilt/*/lib*/clang/<版本>/lib"
        warn "      整个目录拷入: $res_dir/"
      fi
    else
      ok "运行时静态库已就位（lib/linux/*/libunwind.a 可达）"
    fi
  else
    run sh -c "若新资源目录缺 lib 子树，则从相邻完整资源目录整体拷入 lib/unwind 与 builtins"
  fi

  # ---- 自检：逐 Pass 试编译 ----
  TV="$WORK_DIR/selftest"
  CORE_FAIL=0
  if [ "$DRYRUN" = "0" ]; then
    rm -rf "$TV"; mkdir -p "$TV"
    printf '%s\n' \
      'int f(int a,int b){int s=0;' \
      'for(int i=0;i<10;i++){if(i%3)s+=a*i;else s^=b<<i;}' \
      'return s+b;}' \
      'int main(void){return f(3,7)&255;}' > "$TV/t.c"
  fi
  check_pass "控制流平展 fla" required -flegacy-pass-manager -mllvm -fla
  check_pass "虚假控制流 bcf" required -flegacy-pass-manager -mllvm -split -mllvm -split_num=3 -mllvm -bcf -mllvm -bcf_loop=5
  check_pass "指令替换 sub"   required -flegacy-pass-manager -mllvm -sub -mllvm -sub_loop=5
  check_pass "字符串加密 sobf(可选)" optional -flegacy-pass-manager -mllvm -sobf

  # ---- 自检：链接成 .so（模拟 NDK 构建产物形态）并真实执行 ----
  if [ "$DRYRUN" = "0" ]; then
    if "$TB/clang" -O2 -shared -fPIC -Wl,-z,max-page-size=16384 "$TV/t.c" -o "$TV/libt.so" 2>"$TV/link.log"; then
      ok "共享库链接冒烟 ✓ libt.so"
    else
      err "共享库链接失败（含16KB页参数测试）: $(tail -n2 "$TV/link.log" | tr '\n' ' ')"
      CORE_FAIL=1
    fi
    # 注意：测试代码 main() 返回 f(3,7)&255 = 183（非零），
    # 不能用 && 来判断成功，必须用 || true 捕获退出码后再判断。
    # 退出码 < 128 表示正常退出；>= 128 表示被信号杀死。
    if "$TB/clang" -O1 "$TV/t.c" -o "$TV/t.bin" 2>>"$TV/link.log"; then
      "$TV/t.bin" || true
      brc=$?
      if [ "$brc" -lt 128 ] 2>/dev/null; then
        ok "可执行冒烟 ✓ (退出码=$brc，工具链可正常工作)"
      else
        err "可执行文件被信号终止（退出码=$brc，信号=$((brc-128)))"
        CORE_FAIL=1
      fi
    else
      rc=$?
      err "普通模式编译失败（退出码=$rc），工具链本身不可用"
      CORE_FAIL=1
    fi
    if [ "$CORE_FAIL" != "0" ]; then
      err "还原方法: 将 $tb/clang.orig 覆盖回 $tb/clang 即可恢复官方工具链"
      die "自检未通过 —— 中止部署！"
    fi
    ok "★★ OLLVM 工具链自检全部通过 ★★ 目标: $TB/clang"
  else
    run sh -c "clang -O2 -shared -fPIC libt.so 链接冒烟"
    run sh -c "编译生成的可执行文件实际运行一次做最终裁决"
    info "[dry-run] 计划的自检项共 $SELFTEST_DRY_PLANNED 个 Pass + 2 项链接运行冒烟"
  fi
}

# SKIP_REPLACE=1 时表示工具链本身就是 OLLVM 构建（termux 整合包），
# 直接执行同一套校验流程——覆盖写入的正是同目录自身，保证幂等且结论可信。
[ -n "$NDK_DIR" ] || die "内部错误：缺少目标 NDK（--ndk-dir）"
replace_clang "$NDK_DIR"

# ============================================ STEP 5.5 zipalign 独立安装
step "STEP 5.5/6  检查/安装 zipalign （APK 对齐，dcc 打包必需）"
if command -v zipalign >/dev/null 2>&1; then
  ok "zipalign 已可用: $(command -v zipalign)"
else
  ZA_ROOT="$HOME/.local/android-buildtools"
  ZA_BIN="$ZA_ROOT/bin"; ZA_LIB="$ZA_ROOT/lib64"
  if [ -x "$ZA_BIN/zipalign" ] && [ -f "$ZA_LIB/libc++.so" ]; then
    ok "zipalign 已在本地缓存: $ZA_BIN/zipalign （仅需挂到 PATH）"
  else
    info "下载官方 build-tools（约58MB，仅取 zipalign 与 libc++.so）..."
    za_ok=0
    for u in \
      "https://mirrors.cloud.tencent.com/AndroidSDK/build-tools_r34-linux.zip" \
      "https://dl.google.com/android/repository/build-tools_r34-linux.zip"; do
      if run wget -q --show-progress "$u" -O "$WORK_DIR/bt.zip"; then za_ok=1; break; fi
      warn "下载失败，换源重试: $u"
    done
    if [ "$za_ok" != "1" ]; then
      warn "zipalign 自动安装失败 —— 请手动安装 build-tools 并把 zipalign 放入 PATH，否则 dcc 打包阶段会报 FileNotFoundError"
    else
      run unzip -o -q "$WORK_DIR/bt.zip" '*/zipalign' '*/lib64/libc++.so' -d "$WORK_DIR/bt"
      run mkdir -p "$ZA_BIN" "$ZA_LIB" "$HOME/.local/bin"
      run find "$WORK_DIR/bt" -name zipalign   -exec cp {} "$ZA_BIN/" \;
      run find "$WORK_DIR/bt" -name libc++.so  -exec cp {} "$ZA_LIB/" \;
      run chmod 755 "$ZA_BIN/zipalign"
      if [ "$DRYRUN" = "0" ]; then
        printf '#!/usr/bin/env bash\nexport LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "%s/zipalign" "$@"\n' \
          "$ZA_LIB" "$ZA_BIN" > "$HOME/.local/bin/zipalign"
        chmod 755 "$HOME/.local/bin/zipalign"
        if [ -w /usr/local/bin ]; then
          ln -sf "$HOME/.local/bin/zipalign" /usr/local/bin/zipalign
        elif [ -n "$ROOT" ]; then
          $ROOT ln -sf "$HOME/.local/bin/zipalign" /usr/local/bin/zipalign || \
            warn "未能写入 /usr/local/bin —— 请确认 ~/.local/bin 在 PATH 中（重新登录 shell 即可）"
        fi
        "$ZA_BIN/zipalign" 2>&1 | head -n1 || true
      else
        run sh -c "写入 zipalign 包装脚本到 ~/.local/bin 并尽量软链到 /usr/local/bin"
      fi
      rm -f "$WORK_DIR/bt.zip"; rm -rf "$WORK_DIR/bt"
      ok "zipalign 就绪: $ZA_BIN/zipalign （随包 libc++.so 已就位）"
    fi
  fi
fi

# ===================================================== STEP 6. 回写 dcc.cfg
step "STEP 6/6  更新 dcc.cfg"
ENABLE_VAL=1
if [ "$CFG_EDIT" = "1" ] && [ -f dcc.cfg ] && [ -n "$NDK_DIR" ]; then
  if [ "$DRYRUN" = "0" ]; then
    python3 - "$REPO_DIR/dcc.cfg" "$NDK_DIR" "$ENABLE_VAL" <<'PYCFG'
import json, sys
path, ndk, enable = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = json.load(f)
cfg["ndk_dir"] = ndk
cfg.setdefault("ollvm", {})
cfg["ollvm"]["enable"] = (enable == "1")
    # clang13 默认 New PM 会静默忽略 legacy 注册的混淆 Pass，
    # 必须保证 -flegacy-pass-manager 存在，否则混淆是假绿
    fl = str(cfg["ollvm"].get("flags", ""))
    if "-flegacy-pass-manager" not in fl:
        cfg["ollvm"]["flags"] = ("-flegacy-pass-manager " + fl).strip()
with open(path, "w") as f:
    json.dump(cfg, f, indent=4, ensure_ascii=False)
PYCFG
    ok "dcc.cfg 已更新 → ndk_dir=$NDK_DIR , ollvm.enable=true , flags 含 -flegacy-pass-manager"
  else
    run python3 - "$REPO_DIR/dcc.cfg" "$NDK_DIR" "$ENABLE_VAL"
    info "[dry-run] 以上命令会把 ndk_dir 设为该路径并打开混淆开关"
  fi
else
  warn "保留 dcc.cfg 原样，请人工确认两处配置:"
  warn "  \"ndk_dir\": \"${NDK_DIR:-<你的NDK路径>}\""
  warn "  \"ollvm\": { \"enable\": true, ... }"
fi

# ---------------------------------------------------------------- 收尾报告
step "全部完成 ✔"
cat <<FINAL
${C_G}■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  部署摘要
■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■${C_N}
  • Python 依赖 ........ networkx pydot future pyasn1 cryptography lxml asn1crypto
  • 目标 NDK ........... ${NDK_DIR:-见上文}
  • 官方兜底版本 ....... $NDK_REL（仅在未检测到任何 NDK 时才下载）
  • OLLVM 获取方式 ..... $MODE     来源: ${SRC_BIN:-}
  • 内部目录标签 ....... ${TARGET_TAG:-<termux分支下自动探测>}
  • 混淆开关 ........... dcc.cfg → ollvm.enable = true
  • 下一步加固 ......... python3 dcc.py 你的应用.apk
                          （启动时应看到: You've enabled ollvm flag ... 警告即代表生效）
  • 回滚工具链 ......... 用 NDK 内 bin/clang.orig 覆盖回 bin/clang
  • 清理编译缓存 ....... rm -rf $WORK_DIR  （source 模式约占 35~60GB）

${C_Y}提示:${C_N} 需要调整混淆强度时编辑 dcc.cfg 的 ollvm.flags：
      默认组合(-fla/-split=5/-sub=5/-sobf/-bcf_prob=100)属于激进档；
      初次适配建议先降为 -mllvm -bcf_prob=40 -mllvm -sub_loop=2 试编译全量 ABI，
      确认无误后再逐步调高。四个 ABI 全开时内存与耗时翻四倍，按需裁剪 APP_ABI。
FINAL
info "祝加固顺利!"
