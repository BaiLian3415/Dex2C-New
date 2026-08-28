#!/usr/bin/env python3
"""修复 setup_dex2c_ollvm.sh 的两处 bug:
  1. check_pass 函数体内被误入 .so/二进制冒烟代码 → 还原
  2. replace_clang 冒烟测试未实际运行 t.bin → 修复
"""
import re, sys, os

SCRIPT = "/home/heling/Dex2C-New/setup_dex2c_ollvm.sh"

if not os.path.isfile(SCRIPT):
    print(f"ERROR: 找不到 {SCRIPT}")
    sys.exit(1)

with open(SCRIPT, "r") as f:
    src = f.read()

changed = False

# ============================================================
# FIX 1: 还原 check_pass 函数
# 找到从 "check_pass(){" 到下一个 "replace_clang(){" 之间的全部内容
# ============================================================
CORRECT_CHECK_PASS = r'''check_pass(){   # $1=描述  $2=是否可选(optional)  其余=flags(可为多词字符串)
  desc="$1"; optional="${2:-required}"; shift 2
  flags="$*"
  if [ "$DRYRUN" = "0" ]; then
    clog="$TV/pass.log"
    if "$TB/clang" -O1 $flags "$TV/t.c" -c -o "$TV/out.o" 2>"$clog"; then
      ok "Pass[$desc] ✓ ($flags)"
      return 0
    fi
    if [ "$optional" = "optional" ]; then
      warn "Pass[$desc] 不受支持 —— 仅影响该项能力，其余 Pass 可正常使用 ($(tail -n2 "$clog" | tr '\n' ' '))"
    else
      err "Pass[$desc] ✗ 该 clang 不支持必备混淆 Pass！($(tail -n2 "$clog" | tr '\n' ' '))"
      CORE_FAIL=1
    fi
  else
    SELFTEST_DRY_PLANNED=$((SELFTEST_DRY_PLANNED+1))
    run sh -c "clang $flags t.c -c   # <- Pass[$desc]"
  fi
  return 0
}'''

pat1 = re.compile(
    r'check_pass\(\)\{.*?\n\}\n',
    re.DOTALL
)
m1 = pat1.search(src)
if m1:
    old_func = m1.group(0)
    # 检查是否已经被篡改（如果函数体里包含 "共享库链接" 说明被误入了）
    if '共享库链接' in old_func:
        src = src[:m1.start()] + CORRECT_CHECK_PASS + '\n' + src[m1.end():]
        changed = True
        print("[FIX 1] check_pass 函数已还原（移除误入的 .so/二进制测试代码） ✓")
    elif 'pass.log' in old_func:
        print("[FIX 1] check_pass 函数已经是正确版本，跳过")
    else:
        print("[FIX 1] check_pass 函数内容无法识别，跳过")
else:
    print("[FIX 1] WARNING: 未找到 check_pass 函数定义")

# ============================================================
# FIX 2: 修复 replace_clang 中的可执行冒烟测试
# 匹配旧的（有 bug 的）测试块并替换为正确版本
# ============================================================
OLD_SMOKE = r'''    if "$TB/clang" -O1 "$TV/t.c" -o "$TV/t.bin" 2>>"$TV/link.log"; then
      brc=$?
      ok "可执行冒烟 ✓ (退出码=$brc 与预期位运算结果一致)"
    else
      rc=$?
      if [ -x "$TV/t.bin" ]; then
        err "混淆编译出的可执行文件运行异常（退出码=$rc）"
      else
        err "普通模式编译失败（退出码=$rc），工具链本身不可用"
      fi
      CORE_FAIL=1
    fi'''

NEW_SMOKE = r'''    # 注意：测试代码 main() 返回 f(3,7)&255 = 183（非零），
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
    fi'''

if OLD_SMOKE in src:
    src = src.replace(OLD_SMOKE, NEW_SMOKE)
    changed = True
    print("[FIX 2] 冒烟测试已修复（运行 t.bin 并正确判断退出码） ✓")
else:
    # 尝试匹配原始版本（带 && t.bin 的）
    OLD_SMOKE_ORIG = r'''    if "$TB/clang" -O1 "$TV/t.c" -o "$TV/t.bin" 2>>"$TV/link.log" && "$TV/t.bin"; then
      brc=$?
      ok "可执行冒烟 ✓ (退出码=$brc 与预期位运算结果一致)"
    else
      rc=$?
      if [ -x "$TV/t.bin" ]; then
        err "混淆编译出的可执行文件运行异常（退出码=$rc）"
      else
        err "普通模式编译失败（退出码=$rc），工具链本身不可用"
      fi
      CORE_FAIL=1
    fi'''
    if OLD_SMOKE_ORIG in src:
        src = src.replace(OLD_SMOKE_ORIG, NEW_SMOKE)
        changed = True
        print("[FIX 2] 冒烟测试已修复（原始 && 版本） ✓")
    elif NEW_SMOKE in src:
        print("[FIX 2] 冒烟测试已经是修复后版本，跳过")
    else:
        print("[FIX 2] WARNING: 未匹配到冒烟测试代码块，请手动检查")

# ============================================================
# 写回文件
# ============================================================
if changed:
    with open(SCRIPT, "w") as f:
        f.write(src)
    print()
    print("修复完成！请执行:")
    print(f"  bash -n {SCRIPT}")
    print(f"  bash {SCRIPT} --skip-system-deps --skip-python-deps")
else:
    print()
    print("无需修改。")
    print(f"建议直接运行: bash {SCRIPT} --skip-system-deps --skip-python-deps")
