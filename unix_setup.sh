#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

check_command() { command -v "$1" &> /dev/null; }

# 安全的临时目录管理
TMP_DIRS=()
register_tmp() { TMP_DIRS+=("$1"); }

cleanup() {
    local exit_code=$?
    if [[ ${#TMP_DIRS[@]} -gt 0 ]]; then
        print_info "清理临时目录..."
        for d in "${TMP_DIRS[@]}"; do
            [[ -d "$d" ]] && rm -rf "$d"
        done
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM HUP

# 检查 sudo 权限
check_sudo() {
    if [[ "$EUID" -eq 0 ]]; then return 0; fi
    if sudo -n true 2>/dev/null; then return 0; fi
    print_error "需要 sudo 权限以安装系统依赖。请确保当前用户具有 sudo 权限，或先执行 'sudo -v' 缓存凭据。"
}

check_sudo_cached() {
    if [[ "$EUID" -eq 0 ]]; then return 0; fi
    sudo -n true 2>/dev/null
}

version_ge() {
    python3 -c "import sys; v1=tuple(map(int,'$1'.split('.'))); v2=tuple(map(int,'$2'.split('.'))); sys.exit(0 if v1>=v2 else 1)"
}

abs_path() {
    if [[ "$1" = /* ]]; then echo "$1"; else echo "$(pwd)/$1"; fi
}

get_host_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

HOST_ARCH=$(get_host_arch)

# =============================================================================
# 统一下载函数
# =============================================================================
download_file() {
    local url="$1" output="$2" desc="${3:-文件}" timeout="${4:-120}" retries="${5:-3}"

    print_info "开始下载 $desc..."
    print_info "  URL: $url"
    print_info "  目标: $output"
    print_info "  超时: ${timeout}s, 重试: $retries 次"

    local success=false attempt=1
    while [[ $attempt -le $retries ]]; do
        if [[ $attempt -gt 1 ]]; then
            print_warn "第 $((attempt-1)) 次下载失败，剩余 $((retries-attempt+1)) 次重试..."
            sleep 2
        fi

        if check_command wget; then
            if wget --timeout="$timeout" --tries=1 --progress=dot:giga \
                    -O "$output" "$url" 2>&1 | tail -n 10; then
                success=true; break
            fi
        elif check_command curl; then
            if curl -L --max-time "$timeout" --connect-timeout 30 \
                    --retry 1 --retry-delay 2 \
                    --progress-bar -o "$output" "$url" 2>&1 | tail -n 10; then
                success=true; break
            fi
        else
            print_error "需要 wget 或 curl 以下载 $desc"
        fi
        attempt=$((attempt + 1))
    done

    if [[ "$success" != "true" ]]; then
        print_error "下载 $desc 失败（已重试 $retries 次）。\n  URL: $url\n  请检查网络连接，或手动下载后放置到目标位置。"
    fi

    if [[ ! -f "$output" || ! -s "$output" ]]; then
        print_error "下载 $desc 后文件为空或不存在，可能下载被中断。"
    fi

    local fsize; fsize=$(du -h "$output" 2>/dev/null | cut -f1)
    print_success "$desc 下载完成 ($fsize)"
}

# =============================================================================
# 【v4 修复】安全解压函数 —— unzip -o + Python zipfile fallback
# =============================================================================
safe_unzip_extract() {
    local zipfile="$1" pattern="$2" destdir="$3"

    print_info "解压: $pattern 从 $zipfile 到 $destdir"
    mkdir -p "$destdir"

    local basename; basename=$(basename "$pattern")
    if [[ -f "$destdir/$basename" ]]; then
        print_info "  删除已存在的 $destdir/$basename"
        rm -f "$destdir/$basename"
    fi

    if check_command unzip; then
        print_info "  使用 unzip 提取..."
        if unzip -o -q -j "$zipfile" "$pattern" -d "$destdir" 2>/dev/null; then
            print_success "  unzip 提取成功"
            return 0
        else
            print_warn "  unzip 提取失败，尝试备用方案..."
        fi
    fi

    if check_command python3; then
        print_info "  使用 Python zipfile 提取..."
        if python3 -c "
import zipfile, sys, os
zip_path = r'$zipfile'
pattern = r'$pattern'
dest = r'$destdir'
try:
    with zipfile.ZipFile(zip_path, 'r') as z:
        found = [n for n in z.namelist() if n.endswith(pattern) or n == pattern]
        if not found:
            found = [n for n in z.namelist() if pattern in n]
        if not found:
            print(f'ERROR: 在 zip 中未找到匹配 {pattern} 的文件')
            sys.exit(1)
        for name in found:
            data = z.read(name)
            out_path = os.path.join(dest, os.path.basename(name))
            with open(out_path, 'wb') as f:
                f.write(data)
            print(f'EXTRACTED: {name} -> {out_path}')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1; then
            print_success "  Python zipfile 提取成功"
            return 0
        else
            print_warn "  Python zipfile 提取也失败了"
        fi
    fi

    return 1
}

find_java() {
    if check_command java; then echo "java"; return 0; fi
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        echo "$JAVA_HOME/bin/java"; return 0
    fi
    local candidates=(
        /usr/bin/java /usr/lib/jvm/*/bin/java /usr/lib/jvm/java-*/bin/java
        /opt/jdk*/bin/java /opt/openjdk*/bin/java "$HOME/.sdkman/candidates/java/*/bin/java"
    )
    for c in "${candidates[@]}"; do
        for f in $c; do
            if [[ -x "$f" ]]; then echo "$f"; return 0; fi
        done
    done
    return 1
}

get_java_major_version() {
    local java_cmd="$1"
    local version_str; version_str=$("$java_cmd" -version 2>&1)
    local ver; ver=$(echo "$version_str" | grep -i "version" | head -n1 | sed -E 's/.*"([0-9]+)(\.[0-9]+)*.*/\1/')
    if [[ "$ver" == "1" ]]; then
        ver=$(echo "$version_str" | grep -i "version" | head -n1 | sed -E 's/.*"1\.([0-9]+).*/\1/')
    fi
    echo "$ver"
}

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &> /dev/null; then echo "linux_apt"
        elif command -v dnf &> /dev/null; then echo "linux_yum"
        elif command -v yum &> /dev/null; then echo "linux_yum"
        elif command -v pacman &> /dev/null; then echo "linux_pacman"
        else print_error "不支持的 Linux 发行版"; fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        check_command brew && echo "macos" || print_error "macOS 需要先安装 Homebrew"
    else
        print_error "不支持的操作系统: $OSTYPE"
    fi
}

OS_TYPE=$(detect_os)
print_info "检测到系统: $OS_TYPE, 架构: $HOST_ARCH"

OLLVM_BRANCH="llvm-13.x"
OLLVM_EXPECTED_COMMIT="${OLLVM_EXPECTED_COMMIT:-}"

# ==================== 检查 apktool ====================
check_apktool() {
    local TOOLS_DIR="tools"
    local JAR="$TOOLS_DIR/apktool.jar"
    local SCRIPT="$TOOLS_DIR/apktool"

    if [[ ! -f "$JAR" ]]; then
        print_error "缺少 tools/apktool.jar\n\n请手动下载并放置到 tools/ 目录：\n  wget https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar -O tools/apktool.jar\n\n或从其他来源获取后重命名为 apktool.jar 放入 tools/ 目录"
    fi

    if [[ ! -f "$SCRIPT" ]]; then
        print_info "创建 apktool 包装脚本..."
        cat > "$SCRIPT" << 'WRAPPER'
#!/bin/bash
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$script_dir/apktool.jar" ]]; then
    echo "apktool: can't find apktool.jar" >&2
    exit 1
fi
exec java -jar "$script_dir/apktool.jar" "$@"
WRAPPER
        chmod +x "$SCRIPT"
    fi

    if ! bash "$SCRIPT" --version >/dev/null 2>&1; then
        print_warn "apktool 版本检查未通过，但文件已存在，将继续"
    else
        print_success "apktool 已就绪: $(bash "$SCRIPT" --version 2>&1 | head -n1)"
    fi
}

# ==================== 仓库完整性检查 ====================
check_repo_integrity() {
    print_info "检查仓库文件完整性..."
    [[ -f "dcc.py" ]] || print_error "缺少 dcc.py，请在 Dex2C-New 仓库根目录运行"
    [[ -f "requirements.txt" ]] || print_error "缺少 requirements.txt"
    [[ -f "dcc.cfg" ]] || print_error "缺少 dcc.cfg"

    check_apktool

    [[ -f "tools/apksigner.jar" ]] || print_error "缺少 tools/apksigner.jar，请重新克隆仓库"
    [[ -f "tools/manifest-editor.jar" ]] || print_error "缺少 tools/manifest-editor.jar，请重新克隆仓库"
    [[ -d "project" ]] || print_error "缺少 project/ 目录"
    [[ -f "project/jni/Android.mk" ]] || print_error "缺少 project/jni/Android.mk"

    if [[ ! -f "filter.txt" ]]; then
        print_warn "未找到 filter.txt，将创建默认示例"
        cat > filter.txt << 'EOF'
# Dex2C 过滤规则示例
# 白名单：保护 com.example 包下的所有方法
# com/example/.*;.*
#
# 黑名单：排除特定方法（行首加 !）
# !com/example/MainActivity;onCreate(.*)V
EOF
    fi
    print_success "仓库完整性检查通过"
}

# ==================== 系统依赖 ====================
install_sys_deps() {
    print_info "检查系统依赖..."
    if ! check_command python3; then print_error "Python3 未安装"; fi
    local PY_VER; PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if ! version_ge "$PY_VER" "3.8"; then print_error "Python $PY_VER < 3.8"; fi
    print_success "Python $PY_VER OK"

    local need_jdk=true JAVA_CMD; JAVA_CMD=$(find_java) || true
    if [[ -n "$JAVA_CMD" ]]; then
        local jv; jv=$(get_java_major_version "$JAVA_CMD")
        if [[ "$jv" =~ ^[0-9]+$ && "$jv" -ge 17 ]]; then
            print_success "Java $jv OK（跳过 JDK 安装）"
            need_jdk=false
        else
            print_warn "检测到 Java 版本 $jv，需要 17+"
        fi
    fi

    case $OS_TYPE in
        linux_apt)
            check_sudo
            sudo apt-get update
            local pkgs=()
            if [[ "$need_jdk" == true ]]; then
                local jdk=""
                if apt-cache search --names-only '^openjdk-17-jdk$' 2>/dev/null | grep -q 'openjdk-17-jdk'; then
                    jdk="openjdk-17-jdk"
                elif apt-cache search --names-only '^openjdk-21-jdk$' 2>/dev/null | grep -q 'openjdk-21-jdk'; then
                    jdk="openjdk-21-jdk"
                elif apt-cache search --names-only '^default-jdk$' 2>/dev/null | grep -q 'default-jdk'; then
                    jdk="default-jdk"
                fi
                if [[ -n "$jdk" ]]; then pkgs+=("$jdk")
                else print_warn "apt 源中未找到 JDK 包，请手动安装 JDK 17+"; fi
            fi
            pkgs+=(python3 python3-pip python3-venv build-essential cmake git wget unzip)
            sudo apt-get install -y "${pkgs[@]}" || print_error "apt 安装失败"
            ;;
        linux_yum)
            check_sudo
            [[ "$need_jdk" == true ]] && sudo yum install -y java-17-openjdk-devel || true
            sudo yum install -y python3 python3-pip python3-virtualenv gcc-c++ make cmake git wget unzip || print_error "yum 失败"
            ;;
        linux_pacman)
            check_sudo
            [[ "$need_jdk" == true ]] && sudo pacman -Sy --noconfirm jdk17-openjdk || true
            sudo pacman -Sy --noconfirm python python-pip python-virtualenv base-devel cmake git wget unzip || print_error "pacman 失败"
            ;;
        macos)
            [[ "$need_jdk" == true ]] && brew install openjdk@17
            brew install python3 cmake git wget unzip
            ;;
    esac

    print_info "[步骤] 修复 zipalign 的 libc++ 依赖..."
    fix_zipalign_deps
    print_info "[步骤] 检查/安装 zipalign..."
    install_zipalign
    print_success "系统依赖检查完成"
}

# ==================== 修复 zipalign 的 libc++ 依赖 ====================
fix_zipalign_deps() {
    local LIBCPLUS="/usr/lib/x86_64-linux-gnu/libc++.so.1"
    local LIBCPLUS_LINK="/usr/lib/x86_64-linux-gnu/libc++.so"

    if [[ -f "$LIBCPLUS" && ! -f "$LIBCPLUS_LINK" ]]; then
        print_info "修复 zipalign 的 libc++ 库依赖..."
        if check_sudo_cached; then
            if sudo ln -s "$LIBCPLUS" "$LIBCPLUS_LINK" 2>/dev/null && sudo ldconfig 2>/dev/null; then
                print_success "已创建 libc++.so 符号链接"
            else
                print_warn "无法创建 libc++.so 符号链接，将使用 LD_LIBRARY_PATH 备用方案"
                export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
            fi
        else
            print_warn "sudo 凭据未缓存，跳过 libc++.so 符号链接创建（不影响核心功能）"
            print_info "如后续 zipalign 报错缺少 libc++.so，请手动执行："
            print_info "  sudo ln -s /usr/lib/x86_64-linux-gnu/libc++.so.1 /usr/lib/x86_64-linux-gnu/libc++.so"
        fi
    fi
}

# ==================== 安装 zipalign ====================
install_zipalign() {
    if check_command zipalign; then
        print_success "zipalign 已在 PATH 中，跳过安装"
        return 0
    fi

    local ZA="$HOME/.local/bin"
    local URL
    if [[ "$OS_TYPE" == "macos" ]]; then
        URL="https://dl.google.com/android/repository/build-tools_r33-macosx.zip"
    else
        URL="https://dl.google.com/android/repository/build-tools_r33-linux.zip"
    fi
    local ZA_ZIP="/tmp/dex2c-za-$$.zip"

    download_file "$URL" "$ZA_ZIP" "zipalign (Android Build Tools r33)" 120 3

    if safe_unzip_extract "$ZA_ZIP" "android-13/zipalign" "$ZA"; then
        rm -f "$ZA_ZIP"
    else
        rm -f "$ZA_ZIP"
        print_warn "zipalign 自动安装失败，请手动安装 Android SDK build-tools"
        return 1
    fi

    if [[ -x "$ZA/zipalign" ]]; then
        chmod +x "$ZA/zipalign"
        export PATH="$ZA:$PATH"
        print_success "zipalign 已安装到 $ZA"
    else
        print_warn "zipalign 安装后验证失败"
        return 1
    fi
}

# ==================== Python venv + requirements.txt ====================
install_python_deps() {
    local req="${1:-requirements.txt}"
    local venv="${2:-.venv}"
    [[ -f "$req" ]] || print_error "未找到 $req"
    print_info "检测到依赖文件: $(abs_path "$req")"

    if [[ ! -d "$venv" ]]; then
        print_info "创建虚拟环境: $venv"
        python3 -m venv "$venv" || print_error "venv 创建失败"
    else
        print_warn "复用已有虚拟环境: $venv"
    fi

    local pip="$venv/bin/pip"
    [[ -x "$pip" ]] || print_error "pip 未找到: $pip"

    print_info "升级 pip..."
    "$pip" install --upgrade pip >&2 || true
    print_info "从 $req 安装依赖..."
    "$pip" install -r "$req" || print_error "依赖安装失败"
    print_success "Python 依赖安装完成"
    echo "$venv"
}

# ==================== 安装 Android NDK ====================
install_ndk() {
    local VER="${1:-r27c}"
    local BASE="${2:-$HOME/Android/Sdk/ndk}"
    local DIR="$BASE/$VER"

    if [[ -d "$DIR" && -x "$DIR/ndk-build" ]]; then
        print_success "NDK 已存在: $DIR"
        echo "$DIR"; return 0
    fi

    if check_command ndk-build; then
        local EXIST; EXIST=$(dirname "$(command -v ndk-build)")
        print_warn "检测到系统 NDK: $EXIST"
        read -rp "使用现有 NDK？(Y/n) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Nn]$ ]] && echo "$EXIST" && return 0
    fi

    local PLAT="linux"
    [[ "$OS_TYPE" == "macos" ]] && PLAT="darwin"
    local ZIP="android-ndk-$VER-$PLAT.zip"
    local URL="https://dl.google.com/android/repository/$ZIP"
    local TMP="/tmp/dex2c-ndk-$$"
    register_tmp "$TMP"

    mkdir -p "$BASE" "$TMP"
    download_file "$URL" "$TMP/$ZIP" "Android NDK $VER" 300 3

    print_info "解压 NDK（约 1GB+，可能需要几分钟）..."
    unzip -q "$TMP/$ZIP" -d "$TMP"
    local EXTRACT; EXTRACT=$(find "$TMP" -maxdepth 1 -type d -name "android-ndk-*" | head -n1)
    [[ -z "$EXTRACT" ]] && print_error "NDK 解压失败"

    [[ -d "$DIR" ]] && rm -rf "$DIR"
    mv "$EXTRACT" "$DIR"

    [[ -x "$DIR/ndk-build" ]] || print_error "NDK 验证失败"
    print_success "NDK 安装完成: $DIR"
    echo "$DIR"
}

# =============================================================================
# 【v4 修复】跨平台安全的文本替换 —— \n 正确转义为真实换行符
# =============================================================================
safe_patch_file() {
    local file="$1" pattern="$2" replacement="$3"

    if [[ ! -f "$file" ]]; then
        print_warn "补丁目标文件不存在: $file"
        return 1
    fi

    # 使用 Python 进行跨平台安全的文本替换
    # 【v4 关键修复】将 replacement 中的 \\n 替换为真实的换行符
    python3 << EOF
import sys

with open(r"$file", 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()

if r"$pattern" not in content:
    print("[INFO] 补丁目标文本不存在，跳过", file=sys.stderr)
    sys.exit(0)

# 将 Bash 传入的 \\n 替换为真实的换行符
replacement = r"$replacement".replace('\\n', '\n')

if replacement in content:
    print("[INFO] 补丁已存在，跳过", file=sys.stderr)
    sys.exit(0)

content = content.replace(r"$pattern", replacement)

with open(r"$file", 'w', encoding='utf-8') as f:
    f.write(content)

print("[SUCCESS] 补丁已应用", file=sys.stderr)
EOF
}

# ==================== 修复 OLLVM GCC 13+ 兼容性补丁 ====================
apply_ollvm_patches() {
    local WORK_DIR="$1"
    local SIGNALS_H="$WORK_DIR/llvm/include/llvm/Support/Signals.h"
    if [[ -f "$SIGNALS_H" ]] && ! grep -q '#include <cstdint>' "$SIGNALS_H"; then
        print_info "应用 OLLVM GCC 13+ 兼容性补丁..."
        # 【v4 修复】\\n 会被 safe_patch_file 正确转义为换行符
        safe_patch_file "$SIGNALS_H" "#include <string>" "#include <string>\n#include <cstdint>"
        print_success "补丁已应用"
    fi
}

# ==================== 计算安全的编译线程数 ====================
calc_safe_jobs() {
    local cpu; cpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    local mem_mb; mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)

    if [[ "$mem_mb" -eq 0 ]]; then
        if [[ "$OS_TYPE" == "macos" ]]; then
            local mem_bytes; mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 4294967296)
            mem_mb=$((mem_bytes / 1024 / 1024))
        else
            mem_mb=4096
        fi
    fi

    local safe_jobs=$(( mem_mb / 1800 ))
    [[ "$safe_jobs" -lt 1 ]] && safe_jobs=1
    [[ "$safe_jobs" -gt "$cpu" ]] && safe_jobs="$cpu"

    if [[ "$mem_mb" -lt 2048 ]]; then
        safe_jobs=1; print_warn "可用内存仅 ${mem_mb}MB，强制单线程编译防止 OOM"
    elif [[ "$mem_mb" -lt 4096 ]]; then
        safe_jobs=1; print_warn "可用内存仅 ${mem_mb}MB，限制为单线程编译"
    elif [[ "$safe_jobs" -eq 1 ]]; then
        print_warn "可用内存 ${mem_mb}MB，限制为单线程编译"
    else
        print_info "可用内存 ${mem_mb}MB，使用 $safe_jobs 线程编译"
    fi
    echo "$safe_jobs"
}

# ==================== 备份文件轮转 ====================
rotate_backups() {
    local target_dir="$1" pattern="$2" max_backups="${3:-5}"
    local count; count=$(find "$target_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | wc -l)
    if [[ "$count" -ge "$max_backups" ]]; then
        print_info "备份文件超过 ${max_backups} 个，清理旧备份..."
        find "$target_dir" -maxdepth 1 -name "$pattern" -type f -printf '%T@ %p\n' 2>/dev/null | \
            sort -n | head -n -$((max_backups - 1)) | cut -d' ' -f2- | xargs -r rm -f
    fi
}

# ==================== 安装并集成 OLLVM（隔离副本模式） ====================
install_ollvm() {
    local NDK_PATH="$1"
    local INSTALL_DIR="$HOME/Android/ollvm"
    local ORIGINAL_DIR; ORIGINAL_DIR=$(pwd)

    print_info "安装 OLLVM ($OLLVM_BRANCH) ..."

    local NDK_CLANG_DIR=""
    NDK_CLANG_DIR=$(find "$NDK_PATH/toolchains/llvm/prebuilt" -maxdepth 2 -name "bin" -type d 2>/dev/null | head -n1 || true)
    if [[ -z "$NDK_CLANG_DIR" || ! -d "$NDK_CLANG_DIR" ]]; then
        print_warn "无法自动定位 NDK clang 目录，OLLVM 将安装但不会自动集成"
        NDK_CLANG_DIR=""
    fi

    if [[ -x "$INSTALL_DIR/bin/clang" ]]; then
        print_warn "OLLVM 已存在: $INSTALL_DIR"
    else
        print_info "OLLVM 将从源码编译（约需 30-90 分钟，视性能和内存而定）"

        local WORK_DIR="/tmp/dex2c-ollvm-$$"
        register_tmp "$WORK_DIR"
        rm -rf "$WORK_DIR"
        mkdir -p "$WORK_DIR"

        print_info "克隆 OLLVM 源码 (分支: $OLLVM_BRANCH)..."
        if ! GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$OLLVM_BRANCH" \
                --progress https://github.com/heroims/obfuscator.git "$WORK_DIR" 2>&1 | tail -n 20; then
            print_error "OLLVM 源码克隆失败\n\n请检查网络连接，或尝试手动克隆后设置 OLLVM 环境变量。"
        fi

        if [[ -n "$OLLVM_EXPECTED_COMMIT" ]]; then
            local actual_commit; actual_commit=$(cd "$WORK_DIR" && git rev-parse HEAD)
            if [[ "$actual_commit" != "$OLLVM_EXPECTED_COMMIT" ]]; then
                print_error "OLLVM 源码校验失败！\n  期望: $OLLVM_EXPECTED_COMMIT\n  实际: $actual_commit"
            fi
            print_success "OLLVM 源码 commit hash 校验通过"
        fi

        if [[ ! -d "$WORK_DIR/llvm" ]]; then print_error "OLLVM 源码结构异常"; fi

        apply_ollvm_patches "$WORK_DIR"

        mkdir -p "$WORK_DIR/build"
        cd "$WORK_DIR/build"

        print_info "配置 OLLVM 编译..."
        if ! cmake -G "Unix Makefiles" \
            -DCMAKE_BUILD_TYPE=Release \
            -DLLVM_ENABLE_PROJECTS="clang" \
            -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86" \
            -DLLVM_ENABLE_NEW_PASS_MANAGER=OFF \
            -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
            ../llvm; then
            cd "$ORIGINAL_DIR"
            print_error "OLLVM CMake 配置失败"
        fi

        local JOBS; JOBS=$(calc_safe_jobs)

        print_info "开始编译 OLLVM，请耐心等待（首次编译耗时较长）..."
        if ! make -j"$JOBS"; then
            cd "$ORIGINAL_DIR"
            print_error "OLLVM 编译失败\n\n诊断：很可能是内存不足（OOM）导致。\n建议：\n  1. 关闭其他程序释放内存\n  2. 增加 WSL 内存限制（.wslconfig 中 memory=8GB 或更高）\n  3. 增加 Swap 空间：sudo swapoff /swapfile 2>/dev/null; sudo rm -f /swapfile; sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile\n  4. 或选择普通模式（不安装 OLLVM）"
        fi

        print_info "安装 OLLVM..."
        if ! make install; then
            cd "$ORIGINAL_DIR"
            print_error "OLLVM 安装失败"
        fi

        cd "$ORIGINAL_DIR"
        print_success "OLLVM 编译安装完成: $INSTALL_DIR"
    fi

    local OLLVM_NDK_DIR; OLLVM_NDK_DIR="$(dirname "$NDK_PATH")/$(basename "$NDK_PATH")-ollvm"

    if [[ -d "$OLLVM_NDK_DIR" && -x "$OLLVM_NDK_DIR/ndk-build" ]]; then
        print_success "OLLVM NDK 副本已存在: $OLLVM_NDK_DIR"
        NDK_PATH="$OLLVM_NDK_DIR"
    elif [[ -n "$NDK_CLANG_DIR" && -d "$NDK_CLANG_DIR" ]]; then
        print_info "创建 OLLVM 隔离 NDK 副本（避免污染原始 NDK）..."
        print_info "源 NDK: $NDK_PATH"
        print_info "目标: $OLLVM_NDK_DIR"

        if cp -rl "$NDK_PATH" "$OLLVM_NDK_DIR" 2>/dev/null; then
            print_success "已使用硬链接创建 NDK 副本（节省空间）"
        else
            print_warn "硬链接复制失败，使用完整复制..."
            cp -r "$NDK_PATH" "$OLLVM_NDK_DIR"
        fi

        local OLLVM_CLANG_DIR
        OLLVM_CLANG_DIR=$(find "$OLLVM_NDK_DIR/toolchains/llvm/prebuilt" -maxdepth 2 -name "bin" -type d 2>/dev/null | head -n1 || true)

        if [[ -n "$OLLVM_CLANG_DIR" && -d "$OLLVM_CLANG_DIR" ]]; then
            rotate_backups "$OLLVM_CLANG_DIR" "clang.bak.*" 3
            rotate_backups "$OLLVM_CLANG_DIR" "clang++.bak.*" 3

            local BAK_DATE; BAK_DATE=$(date +%Y%m%d%H%M%S)
            [[ -x "$OLLVM_CLANG_DIR/clang" ]] && cp "$OLLVM_CLANG_DIR/clang" "$OLLVM_CLANG_DIR/clang.bak.$BAK_DATE"
            [[ -x "$OLLVM_CLANG_DIR/clang++" ]] && cp "$OLLVM_CLANG_DIR/clang++" "$OLLVM_CLANG_DIR/clang++.bak.$BAK_DATE"

            cp "$INSTALL_DIR/bin/clang" "$OLLVM_CLANG_DIR/clang"
            cp "$INSTALL_DIR/bin/clang++" "$OLLVM_CLANG_DIR/clang++"
            chmod +x "$OLLVM_CLANG_DIR/clang" "$OLLVM_CLANG_DIR/clang++"
            print_success "OLLVM 已集成到隔离 NDK 副本"
            print_info "原 clang 已备份: clang.bak.$BAK_DATE / clang++.bak.$BAK_DATE"

            fix_ollvm_lib_path "$OLLVM_NDK_DIR"
            NDK_PATH="$OLLVM_NDK_DIR"
        else
            print_warn "无法在 NDK 副本中定位 clang 目录，OLLVM 未集成"
        fi
    else
        print_warn "无法定位 NDK clang 目录，OLLVM 未集成到 NDK"
    fi

    print_success "OLLVM 配置完成"
    echo "$NDK_PATH"
}

# ==================== 修复 OLLVM-NDK 库路径不匹配 ====================
fix_ollvm_lib_path() {
    local NDK_PATH="$1"
    local PREBUILT_DIR
    PREBUILT_DIR=$(find "$NDK_PATH/toolchains/llvm/prebuilt" -maxdepth 1 -type d 2>/dev/null | head -n1 || true)

    if [[ -z "$PREBUILT_DIR" ]]; then
        print_warn "未找到 NDK prebuilt 目录，跳过库路径修复"
        return 0
    fi

    local LIB_DIR="$PREBUILT_DIR/lib"
    local LIB64_DIR="$PREBUILT_DIR/lib64"

    local REAL_VER=""
    if [[ -d "$LIB64_DIR/clang" ]]; then
        REAL_VER=$(find "$LIB64_DIR/clang" -maxdepth 1 -type d 2>/dev/null | grep -v "^$LIB64_DIR/clang$" | head -n1 | xargs basename 2>/dev/null || true)
    fi

    if [[ -z "$REAL_VER" ]]; then
        print_warn "未找到 NDK 的 clang 库版本目录，跳过库路径修复"
        return 0
    fi

    if [[ ! -d "$LIB_DIR/clang/13.0.1" ]]; then
        print_info "修复 OLLVM 版本号与 NDK 库路径不匹配..."
        mkdir -p "$LIB_DIR/clang"
        if [[ -d "$LIB_DIR/clang/13.0.1" ]]; then rm -rf "$LIB_DIR/clang/13.0.1"; fi
        ln -s "$LIB64_DIR/clang/$REAL_VER" "$LIB_DIR/clang/13.0.1"
        print_success "已创建库路径符号链接: lib/clang/13.0.1 -> lib64/clang/$REAL_VER"
    else
        print_success "OLLVM 库路径已正确链接"
    fi
}

# ==================== 配置 dcc.cfg（原子写入） ====================
configure_dcc() {
    local NDK_PATH="$1" OLLVM_ENABLE="${2:-false}"
    local BACKUP_SUFFIX; BACKUP_SUFFIX=$(date +%Y%m%d%H%M%S)

    rotate_backups "." "dcc.cfg.bak.*" 5
    cp dcc.cfg "dcc.cfg.bak.$BACKUP_SUFFIX" 2>/dev/null || true

    local OLLVM_PY_BOOL="False"
    [[ "$OLLVM_ENABLE" == "true" ]] && OLLVM_PY_BOOL="True"

    local TMP_CFG="dcc.cfg.tmp.$$"
    python3 << EOF
import json, sys
try:
    with open('dcc.cfg', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    old_ndk = cfg.get('ndk_dir', '未设置')
    cfg['ndk_dir'] = r"""$NDK_PATH"""
    if 'ollvm' not in cfg:
        cfg['ollvm'] = {
            'enable': False,
            'flags': '-fvisibility=hidden -mllvm -fla -mllvm -split -mllvm -split_num=5 -mllvm -sub -mllvm -sub_loop=5 -mllvm -sobf -mllvm -bcf_loop=5 -mllvm -bcf_prob=100'
        }
    cfg['ollvm']['enable'] = $OLLVM_PY_BOOL
    with open(r'$TMP_CFG', 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
        f.write('\n')
    print(f"[INFO] dcc.cfg 已更新", file=sys.stderr)
    print(f"  ndk_dir: {cfg['ndk_dir']}", file=sys.stderr)
    print(f"  ollvm.enable: {cfg['ollvm']['enable']}", file=sys.stderr)
    if old_ndk != r"""$NDK_PATH""":
        print(f"  原 ndk_dir: {old_ndk}", file=sys.stderr)
except Exception as e:
    print(f"[ERROR] 修改 dcc.cfg 失败: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    mv "$TMP_CFG" dcc.cfg
    print_success "dcc.cfg 配置完成"
}

# ==================== 最终验证 ====================
final_check() {
    print_info "执行最终验证..."
    local errors=()

    if ! python3 -c "import json; json.load(open('dcc.cfg'))" 2>/dev/null; then
        errors+=("dcc.cfg JSON 格式损坏")
    fi

    [[ -f ".venv/bin/python" ]] || errors+=("Python 虚拟环境不完整")

    local ndk
    ndk=$(python3 -c "import json; print(json.load(open('dcc.cfg'))['ndk_dir'])" 2>/dev/null) || ndk=""
    if [[ -z "$ndk" || ! -x "$ndk/ndk-build" ]]; then
        errors+=("NDK 路径错误或 ndk-build 不可执行: ${ndk:-'(空)'})")
    fi

    [[ ! -f "tools/apktool.jar" ]] && errors+=("tools/apktool.jar 缺失")

    if [[ ${#errors[@]} -gt 0 ]]; then
        print_error "验证失败:\n  - ${errors[*]}"
    fi
    print_success "所有验证通过！"
}

# ==================== 主流程 ====================
main() {
    if [[ ! -f "dcc.py" ]]; then
        print_warn "未检测到 dcc.py，请确保在 Dex2C-New 仓库根目录运行"
        read -rp "是否继续？(y/N) " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi

    print_info "请选择安装模式:"
    echo "  [1] 普通模式 - 下载标准 NDK（推荐，稳定）" >&2
    echo "  [2] OLLVM 模式 - 下载兼容 NDK + 编译 OLLVM 并集成（耗时较长，需要 4GB+ 内存）" >&2
    local choice=""
    while [[ "$choice" != "1" && "$choice" != "2" ]]; do
        read -rp "输入 1 或 2 (默认 1): " choice
        [[ -z "$choice" ]] && choice="1"
    done

    local ENABLE_OLLVM="false" NDK_VERSION="r27c"
    if [[ "$choice" == "2" ]]; then
        ENABLE_OLLVM="true"; NDK_VERSION="r25c"
        print_info "已选择 OLLVM 模式（NDK $NDK_VERSION + OLLVM $OLLVM_BRANCH）"
    else
        print_info "已选择普通模式（NDK $NDK_VERSION）"
    fi

    check_repo_integrity
    install_sys_deps

    local VENV_PATH; VENV_PATH=$(install_python_deps "requirements.txt" ".venv")
    local NDK_PATH; NDK_PATH=$(install_ndk "$NDK_VERSION" "$HOME/Android/Sdk/ndk")

    if [[ "$ENABLE_OLLVM" == "true" ]]; then
        NDK_PATH=$(install_ollvm "$NDK_PATH")
    fi

    configure_dcc "$NDK_PATH" "$ENABLE_OLLVM"
    final_check

    print_success "========== Dex2C-New 环境配置完成 =========="
    echo "" >&2
    echo "使用步骤:" >&2
    echo "  1. source $VENV_PATH/bin/activate" >&2
    echo "  2. 编辑 filter.txt 配置需要保护的方法" >&2
    echo "  3. python dcc.py -a input.apk -o output.apk" >&2
    echo "" >&2
    echo "NDK 路径:  $NDK_PATH" >&2
    echo "虚拟环境:  $VENV_PATH" >&2
    echo "配置文件:  $(abs_path dcc.cfg)" >&2
    if [[ "$ENABLE_OLLVM" == "true" ]]; then
        echo "OLLVM:     已启用（使用隔离 NDK 副本，不影响原始 NDK）" >&2
    fi
}

main "$@"
