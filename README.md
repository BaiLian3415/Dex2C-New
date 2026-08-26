# Dex2C-New

> 将 Android APK 中的 Dalvik 字节码转换为 Native C 代码并重新编译，提升代码安全性。

---

## 致谢

- **[amimo](https://github.com/amimo/dcc)** —— Dex2C 原始作者，感谢其开创性的 Dalvik-to-C 转换方案与核心实现。
- **[iBotPeaches](https://github.com/iBotPeaches/Apktool)** —— Apktool 作者，提供 APK 反编译/回编译基础工具。
- **[heroims](https://github.com/heroims/obfuscator)** —— OLLVM (obfuscator) 维护者，提供 LLVM 13.x 混淆支持。

---

## 功能特性

- **Dalvik → C 转换**：将指定的 Java/Dalvik 方法转换为 C 代码，通过 Android NDK 编译为原生库
- **APK 自动处理**：自动反编译、修改、回编译、签名，无需手动干预
- **OLLVM 混淆（可选）**：集成 OLLVM 控制流平坦化、虚假控制流、字符串加密等保护
- **跨平台安装**：提供 Linux/macOS/WSL (`setup.sh`) 与 Windows (`setup.ps1`) 一键安装脚本

---

## 环境要求

| 依赖 | 版本要求 | 说明 |
|------|---------|------|
| Python | ≥ 3.8 | 运行主程序 |
| JDK | ≥ 17 | 编译与签名 |
| Android NDK | r25c (OLLVM) / r27c (普通) | 编译 Native 代码 |
| C++ 编译器 | GCC/Clang/MSVC | OLLVM 编译需要 |

---

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/BaiLian3415/Dex2C-New.git
cd Dex2C-New
```

### 2. 运行安装脚本

#### Linux / macOS / WSL

```bash
chmod +x unix_setup.sh
./unix_setup.sh
```

按提示选择模式：
- **模式 1（推荐）**：标准 NDK r27c，稳定可靠
- **模式 2**：NDK r25c + OLLVM 编译集成（需要 4GB+ 内存，耗时较长）

#### Windows (PowerShell)

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\windows_setup.ps1
```

> Windows OLLVM 模式需预先安装 **Visual Studio 2019/2022** 的「使用 C++ 的桌面开发」工作负载。

### 3. 激活虚拟环境

```bash
# Linux / macOS / WSL
source .venv/bin/activate

# Windows PowerShell
.venv\Scripts\Activate.ps1
```

### 4. 配置过滤规则

编辑 `filter.txt`，指定需要转换/保护的方法：

```text
# 白名单：保护 com.example 包下的所有方法
com/example/.*;.*

# 黑名单：排除特定方法（行首加 !）
!com/example/MainActivity;onCreate(.*)V
```

### 5. 运行 Dex2C

```bash
python dcc.py -a input.apk -o output.apk
```

---

---

## OLLVM 混淆说明

选择模式 2 后，脚本自动完成：

1. 克隆并编译 OLLVM (heroims/obfuscator, `llvm-13.x`)
2. 替换 NDK 中的 `clang`/`clang++`
3. 在 `dcc.cfg` 中启用 `ollvm.enable`

**默认混淆参数：**

```json
{
    "enable": true,
    "flags": "-fvisibility=hidden -mllvm -fla -mllvm -split -mllvm -split_num=5 -mllvm -sub -mllvm -sub_loop=5 -mllvm -sobf -mllvm -bcf_loop=5 -mllvm -bcf_prob=100"
}
```

修改 `dcc.cfg` 中的 `ollvm.flags` 即可调整。

---

## 许可证

本项目遵循开源许可证发布。请遵守相关协议使用。

---

## 致谢

再次感谢 [amimo](https://github.com/amimo/dcc) 提供 Dex2C 原始实现，以及所有上游开源项目的贡献者。
