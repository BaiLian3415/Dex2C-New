#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ==================== 全局清理注册表 ====================
$script:TempDirs = [System.Collections.ArrayList]::new()
$script:OriginalLocation = Get-Location

function Register-TempDir {
    param([string]$Path)
    [void]$script:TempDirs.Add($Path)
}

function Clear-TempDirs {
    foreach ($d in $script:TempDirs) {
        if (Test-Path $d) {
            try {
                Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Warn "无法清理临时目录: $d"
            }
        }
    }
    $script:TempDirs.Clear()
    # 确保回到原始目录
    if ($script:OriginalLocation) {
        Set-Location $script:OriginalLocation -ErrorAction SilentlyContinue
    }
}

# 注册退出时清理
trap {
    Clear-TempDirs
    break
}

# ==================== 颜色输出 ====================
function Write-Info    { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-ErrorX  { param([string]$Message) 
    Clear-TempDirs
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1 
}

function Test-Command { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ==================== 管理员权限检查 ====================
function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        Write-Warn "某些操作（如创建 Junction 链接）需要管理员权限。"
        Write-Warn "如果后续步骤失败，请以管理员身份重新运行 PowerShell 后重试。"
    }
}

# ==================== 动态检测 Host 架构 ====================
function Get-HostArch {
    $arch = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
    switch ($arch) {
        "AMD64"  { return "x86_64" }
        "x86"    { return "x86" }
        "ARM64"  { return "arm64" }
        default  { return $arch.ToLower() }
    }
}

$HOST_ARCH = Get-HostArch

function Find-Java {
    if (Test-Command "java") { return "java" }
    if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) { 
        return "$env:JAVA_HOME\bin\java.exe" 
    }
    $candidates = @(
        "C:\Program Files\Java\*\bin\java.exe",
        "C:\Program Files\Eclipse Adoptium\*\bin\java.exe",
        "C:\Program Files\Microsoft\jdk-*\bin\java.exe",
        "C:\Program Files (x86)\Java\*\bin\java.exe",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium\*\bin\java.exe"
    )
    foreach ($pattern in $candidates) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# 更健壮的 Java 版本检测
function Get-JavaMajorVersion {
    param([string]$JavaCmd)
    $versionStr = & $JavaCmd -version 2>&1 | Out-String
    # 匹配多种格式："17.0.8", "1.8.0_361", "21.0.2+13-LTS"
    if ($versionStr -match 'version\s+"(\d+)(?:\.(\d+))?(?:\.(\d+))?') {
        $major = [int]$matches[1]
        # 处理 1.8 风格
        if ($major -eq 1 -and $matches[2]) {
            return [int]$matches[2]
        }
        return $major
    }
    return 0
}

function Test-VersionGe {
    param([string]$v1, [string]$v2)
    $result = python -c "import sys; v1=tuple(map(int,'$v1'.split('.'))); v2=tuple(map(int,'$v2'.split('.'))); sys.exit(0 if v1>=v2 else 1)"
    return $result -eq 0
}

$OLLVM_BRANCH = "llvm-13.x"
# 可选：设置 OLLVM 期望的 commit hash 以校验源码完整性
$OLLVM_EXPECTED_COMMIT = $env:OLLVM_EXPECTED_COMMIT

# ==================== 检查 apktool（不自动下载） ====================
function Test-Apktool {
    $jar = "tools\apktool.jar"
    $bat = "tools\apktool.bat"

    if (-not (Test-Path $jar)) {
        Write-ErrorX "缺少 tools\apktool.jar`n`n请手动下载并放置到 tools\ 目录：`n  https://github.com/iBotPeaches/Apktool/releases`n`n下载后重命名为 apktool.jar 放入 tools\ 文件夹"
    }

    if (-not (Test-Path $bat)) {
        Write-Info "创建 apktool.bat 包装脚本..."
        $wrapper = '@echo off' + "`r`n" + 'java -jar "%~dp0\apktool.jar" %*'
        Set-Content -Path $bat -Value $wrapper -Encoding ASCII
    }

    Write-Success "apktool 已就绪"
}

# ==================== 仓库完整性检查 ====================
function Test-RepoIntegrity {
    Write-Info "检查仓库文件完整性..."
    if (-not (Test-Path "dcc.py")) { Write-ErrorX "缺少 dcc.py，请在 Dex2C-New 仓库根目录运行" }
    if (-not (Test-Path "requirements.txt")) { Write-ErrorX "缺少 requirements.txt" }
    if (-not (Test-Path "dcc.cfg")) { Write-ErrorX "缺少 dcc.cfg" }

    Test-Apktool

    if (-not (Test-Path "tools\apksigner.jar")) { Write-ErrorX "缺少 tools\apksigner.jar，请重新克隆仓库" }
    if (-not (Test-Path "tools\manifest-editor.jar")) { Write-ErrorX "缺少 tools\manifest-editor.jar，请重新克隆仓库" }
    if (-not (Test-Path "project")) { Write-ErrorX "缺少 project\ 目录" }
    if (-not (Test-Path "project\jni\Android.mk")) { Write-ErrorX "缺少 project\jni\Android.mk" }

    if (-not (Test-Path "filter.txt")) {
        Write-Warn "未找到 filter.txt，将创建默认示例"
        $content = @"
# Dex2C 过滤规则示例
# 白名单：保护 com.example 包下的所有方法
# com/example/.*;.*
#
# 黑名单：排除特定方法（行首加 !）
# !com/example/MainActivity;onCreate(.*)V
"@
        Set-Content "filter.txt" -Value $content -Encoding UTF8
    }
    Write-Success "仓库完整性检查通过"
}

# ==================== 系统依赖检查 ====================
function Install-SystemDeps {
    Write-Info "检查系统依赖..."

    if (-not (Test-Command "python")) { Write-ErrorX "Python 未安装，请先安装 Python 3.8+" }
    $pyVer = python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    if (-not (Test-VersionGe $pyVer "3.8")) { Write-ErrorX "Python $pyVer < 3.8" }
    Write-Success "Python $pyVer OK"

    $javaCmd = Find-Java
    $needJdk = $true
    if ($javaCmd) {
        $jv = Get-JavaMajorVersion $javaCmd
        if ($jv -ge 17) {
            Write-Success "Java $jv OK（跳过 JDK 安装提示）"
            $needJdk = $false
        } else {
            Write-Warn "检测到 Java 版本 $jv，需要 17+"
        }
    }
    if ($needJdk) {
        Write-Warn "未检测到 Java 17+，请从 https://adoptium.net 手动安装 JDK 17 或更高版本"
    }

    # 安装 zipalign（Windows 版）
    if (-not (Test-Command "zipalign")) {
        Write-Info "下载 zipalign..."
        $zaDir = "$env:USERPROFILE\.local\bin"
        New-Item -ItemType Directory -Force -Path $zaDir | Out-Null
        $url = "https://dl.google.com/android/repository/build-tools_r33-windows.zip"
        $zipFile = "$env:TEMP\build-tools-win-$$.zip"
        $extractDir = "$env:TEMP\build-tools-win-$$"
        Register-TempDir $extractDir

        try {
            Invoke-WebRequest -Uri $url -OutFile $zipFile -UseBasicParsing
            Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
            $zipalignExe = Get-ChildItem $extractDir -Recurse -Filter "zipalign.exe" | Select-Object -First 1
            if ($zipalignExe) {
                Copy-Item $zipalignExe.FullName "$zaDir\zipalign.exe" -Force
                $env:Path = "$zaDir;$env:Path"
                Write-Success "zipalign 已安装到 $zaDir"
            }
        } catch {
            Write-Warn "zipalign 下载失败，请手动安装 Android SDK build-tools"
        } finally {
            if (Test-Path $zipFile) { Remove-Item $zipFile -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Success "系统依赖检查完成"
}

# ==================== Python venv + requirements.txt ====================
function Install-PythonDeps {
    param([string]$ReqFile = "requirements.txt", [string]$VenvDir = ".venv")

    if (-not (Test-Path $ReqFile)) { Write-ErrorX "未找到 $ReqFile" }
    Write-Info "检测到依赖文件: $(Resolve-Path $ReqFile)"

    if (-not (Test-Path $VenvDir)) {
        Write-Info "创建虚拟环境: $VenvDir"
        python -m venv "$VenvDir"
        Write-Success "虚拟环境创建成功"
    } else {
        Write-Warn "复用已有虚拟环境: $VenvDir"
    }

    $pip = "$VenvDir\Scripts\pip.exe"
    if (-not (Test-Path $pip)) { Write-ErrorX "虚拟环境中 pip 未找到" }

    Write-Info "升级 pip..."
    & $pip install --upgrade pip | Out-String | Write-Host -ForegroundColor DarkGray
    Write-Info "从 $ReqFile 安装依赖..."
    & $pip install -r "$ReqFile"
    if ($LASTEXITCODE -ne 0) { Write-ErrorX "Python 依赖安装失败" }

    Write-Success "Python 依赖安装完成"
    return (Resolve-Path $VenvDir).Path
}

# ==================== NDK ====================
function Install-NDK {
    param([string]$Version = "r27c", [string]$BaseDir = "$env:USERPROFILE\Android\Sdk\ndk")
    $dir = "$BaseDir\$Version"

    if ((Test-Path "$dir\ndk-build.cmd") -or (Test-Path "$dir\ndk-build")) {
        Write-Success "NDK 已存在: $dir"
        return $dir
    }

    Write-Info "下载 NDK $Version..."
    $zip = "android-ndk-$Version-windows.zip"
    $url = "https://dl.google.com/android/repository/$zip"
    $tmp = "$env:TEMP\dex2c-ndk-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    Register-TempDir $tmp
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        Invoke-WebRequest -Uri $url -OutFile "$tmp\$zip" -UseBasicParsing
        Write-Info "解压 NDK（约 1GB+，可能需要几分钟）..."
        Expand-Archive -Path "$tmp\$zip" -DestinationPath $tmp -Force
        $extracted = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like "android-ndk-*" } | Select-Object -First 1
        if (-not $extracted) { throw "NDK 解压失败" }

        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Move-Item $extracted.FullName $dir
        Write-Success "NDK 安装完成: $dir"
        return $dir
    } catch {
        Write-ErrorX "NDK 安装失败: $_"
    }
}

# ==================== OLLVM 补丁（跨平台安全替换） ====================
function Apply-OllvmPatches {
    param([string]$WorkDir)
    $signalsH = "$WorkDir\llvm\include\llvm\Support\Signals.h"
    if (Test-Path $signalsH) {
        $content = Get-Content $signalsH -Raw -ErrorAction SilentlyContinue
        if ($content -and -not $content.Contains('#include <cstdint>')) {
            Write-Info "应用 OLLVM GCC 13+ 兼容性补丁..."
            $content = $content.Replace('#include <string>', "#include <string>`r`n#include <cstdint>")
            Set-Content $signalsH $content -NoNewline -Encoding UTF8
            Write-Success "补丁已应用"
        }
    }
}

# ==================== 计算安全线程数 ====================
function Get-SafeJobs {
    $cpu = [Environment]::ProcessorCount
    $memBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $memMB = [math]::Floor($memBytes / 1MB)

    $safe = [math]::Floor($memMB / 1800)
    if ($safe -lt 1) { $safe = 1 }
    if ($safe -gt $cpu) { $safe = $cpu }

    if ($memMB -lt 4096) {
        $safe = 1
        Write-Warn "内存仅 $([math]::Round($memMB/1024,1))GB，限制为单线程编译防止 OOM"
    } else {
        Write-Info "内存 $([math]::Round($memMB/1024,1))GB，使用 $safe 线程编译"
    }
    return $safe
}

# ==================== Visual Studio 检测（增强版） ====================
function Find-VSGenerator {
    # 优先使用 vswhere（Visual Studio 安装程序自带）
    $vswherePaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    foreach ($vsw in $vswherePaths) {
        if (Test-Path $vsw) {
            $installs = & $vsw -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
            foreach ($inst in $installs) {
                $ver = [int]$inst.installationVersion.Split('.')[0]
                if ($ver -ge 17) { return "Visual Studio 17 2022" }
                if ($ver -ge 16) { return "Visual Studio 16 2019" }
            }
        }
    }

    # 回退：通过 cmake --help 检测
    $gens = cmake --help 2>&1 | Select-String "Visual Studio"
    if ($gens -match "Visual Studio 17 2022") { return "Visual Studio 17 2022" }
    if ($gens -match "Visual Studio 16 2019") { return "Visual Studio 16 2019" }

    return $null
}

# ==================== 备份文件轮转 ====================
function Rotate-Backups {
    param([string]$TargetDir, [string]$Pattern, [int]$MaxBackups = 5)

    $backups = Get-ChildItem $TargetDir -Filter $Pattern -File -ErrorAction SilentlyContinue | 
        Sort-Object LastWriteTime
    if ($backups.Count -ge $MaxBackups) {
        Write-Info "备份文件超过 $MaxBackups 个，清理旧备份..."
        $toRemove = $backups | Select-Object -First ($backups.Count - $MaxBackups + 1)
        foreach ($b in $toRemove) {
            Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==================== 安装并集成 OLLVM（隔离副本模式） ====================
function Install-Ollvm {
    param([string]$NdkPath)
    $installDir = "$env:USERPROFILE\Android\ollvm"
    $originalDir = Get-Location

    Write-Info "安装 OLLVM ($OLLVM_BRANCH) ..."

    # 定位 NDK clang 目录（动态探测，不硬编码架构）
    $ndkClangDir = $null
    $prebuiltDirs = Get-ChildItem "$NdkPath\toolchains\llvm\prebuilt" -Directory -ErrorAction SilentlyContinue
    foreach ($pd in $prebuiltDirs) {
        $binDir = Get-ChildItem $pd.FullName -Filter "bin" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($binDir) {
            $ndkClangDir = $binDir.FullName
            break
        }
    }

    if (-not $ndkClangDir) {
        Write-Warn "无法自动定位 NDK clang 目录，OLLVM 将安装但不会自动集成"
    }

    if (Test-Path "$installDir\bin\clang.exe") {
        Write-Warn "OLLVM 已存在: $installDir"
    } else {
        Write-Info "OLLVM 将从源码编译（约需 30-90 分钟）"
        Write-Warn "请确保已安装 Visual Studio 2022/2019 的 '使用 C++ 的桌面开发' 工作负载"

        if (-not (Test-Command "cmake")) { Write-ErrorX "OLLVM 编译需要 CMake，请先安装" }
        if (-not (Test-Command "git")) { Write-ErrorX "OLLVM 编译需要 Git，请先安装" }

        $workDir = "$env:TEMP\dex2c-ollvm-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
        Register-TempDir $workDir
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $workDir | Out-Null

        Write-Info "克隆 OLLVM 源码 (分支: $OLLVM_BRANCH)..."
        git clone --depth 1 -b $OLLVM_BRANCH https://github.com/heroims/obfuscator.git "$workDir"
        if ($LASTEXITCODE -ne 0) { Write-ErrorX "OLLVM 源码克隆失败" }
        if (-not (Test-Path "$workDir\llvm")) { Write-ErrorX "OLLVM 源码结构异常" }

        # 可选：校验 commit hash
        if ($OLLVM_EXPECTED_COMMIT) {
            $actualCommit = (git -C "$workDir" rev-parse HEAD).Trim()
            if ($actualCommit -ne $OLLVM_EXPECTED_COMMIT) {
                Write-ErrorX "OLLVM 源码校验失败！`n  期望: $OLLVM_EXPECTED_COMMIT`n  实际: $actualCommit`n`n仓库可能已被篡改，请检查 OLLVM_EXPECTED_COMMIT 配置。"
            }
            Write-Success "OLLVM 源码 commit hash 校验通过"
        }

        Apply-OllvmPatches $workDir

        $buildDir = "$workDir\build"
        New-Item -ItemType Directory -Path $buildDir | Out-Null
        Set-Location $buildDir

        $vsGenerator = Find-VSGenerator
        if (-not $vsGenerator) {
            Set-Location $originalDir
            Write-ErrorX "未找到支持的 Visual Studio 版本（需要 2019 或 2022）`n`n建议安装 Visual Studio 2022 Community 并勾选 '使用 C++ 的桌面开发' 工作负载。"
        }

        Write-Info "配置 OLLVM 编译 (Generator: $vsGenerator)..."
        cmake -G $vsGenerator -A x64 `
            -DCMAKE_BUILD_TYPE=Release `
            -DLLVM_ENABLE_PROJECTS="clang" `
            -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86" `
            -DLLVM_ENABLE_NEW_PASS_MANAGER=OFF `
            -DCMAKE_INSTALL_PREFIX="$installDir" `
            "..\llvm"
        if ($LASTEXITCODE -ne 0) {
            Set-Location $originalDir
            Write-ErrorX "OLLVM CMake 配置失败"
        }

        $jobs = Get-SafeJobs
        Write-Info "开始编译 OLLVM（使用 $jobs 线程），请耐心等待..."
        cmake --build . --config Release --parallel $jobs
        if ($LASTEXITCODE -ne 0) {
            Set-Location $originalDir
            Write-ErrorX "OLLVM 编译失败`n`n诊断：可能是内存不足或缺少 Visual Studio 组件`n建议：关闭其他程序释放内存，或增加虚拟内存（页面文件）大小"
        }

        Write-Info "安装 OLLVM..."
        cmake --install . --config Release
        if ($LASTEXITCODE -ne 0) {
            Set-Location $originalDir
            Write-ErrorX "OLLVM 安装失败"
        }

        Set-Location $originalDir
        Write-Success "OLLVM 编译安装完成: $installDir"
    }

    # 创建隔离的 NDK 副本用于 OLLVM，避免污染原始 NDK
    $ollvmNdkDir = "$NdkPath-ollvm"

    if (Test-Path "$ollvmNdkDir\ndk-build.cmd") {
        Write-Success "OLLVM NDK 副本已存在: $ollvmNdkDir"
        $NdkPath = $ollvmNdkDir
    } elseif ($ndkClangDir -and (Test-Path $ndkClangDir)) {
        Write-Info "创建 OLLVM 隔离 NDK 副本（避免污染原始 NDK）..."
        Write-Info "源 NDK: $NdkPath"
        Write-Info "目标: $ollvmNdkDir"

        # 使用 robocopy 进行可靠复制（支持长路径、断点续传、多线程）
        if (Test-Path $ollvmNdkDir) { Remove-Item $ollvmNdkDir -Recurse -Force }
        $robocopyResult = robocopy "$NdkPath" "$ollvmNdkDir" /E /MT:8 /R:2 /W:1 /NJH /NJS
        if ($LASTEXITCODE -ge 8) {
            # robocopy 返回码 >= 8 表示有错误
            Write-Warn "robocopy 可能遇到问题（返回码: $LASTEXITCODE），尝试回退到 Copy-Item..."
            Copy-Item $NdkPath $ollvmNdkDir -Recurse -Force
        }
        Write-Success "已创建 NDK 副本"

        # 在副本中替换 clang
        $ollvmClangDir = $null
        $prebuiltDirs = Get-ChildItem "$ollvmNdkDir\toolchains\llvm\prebuilt" -Directory -ErrorAction SilentlyContinue
        foreach ($pd in $prebuiltDirs) {
            $binDir = Get-ChildItem $pd.FullName -Filter "bin" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($binDir) {
                $ollvmClangDir = $binDir.FullName
                break
            }
        }

        if ($ollvmClangDir -and (Test-Path $ollvmClangDir)) {
            # 轮转备份
            Rotate-Backups $ollvmClangDir "clang.bak.*.exe" 3
            Rotate-Backups $ollvmClangDir "clang++.bak.*.exe" 3

            $bakDate = Get-Date -Format "yyyyMMddHHmmss"
            if (Test-Path "$ollvmClangDir\clang.exe") { 
                Copy-Item "$ollvmClangDir\clang.exe" "$ollvmClangDir\clang.bak.$bakDate.exe" -Force 
            }
            if (Test-Path "$ollvmClangDir\clang++.exe") { 
                Copy-Item "$ollvmClangDir\clang++.exe" "$ollvmClangDir\clang++.bak.$bakDate.exe" -Force 
            }

            Copy-Item "$installDir\bin\clang.exe" "$ollvmClangDir\clang.exe" -Force
            Copy-Item "$installDir\bin\clang++.exe" "$ollvmClangDir\clang++.exe" -Force
            Write-Success "OLLVM 已集成到隔离 NDK 副本"
            Write-Info "原 clang 已备份: clang.bak.$bakDate.exe / clang++.bak.$bakDate.exe"

            # 修复 OLLVM 版本号与 NDK 库路径不匹配
            Fix-OllvmLibPath $ollvmNdkDir
            $NdkPath = $ollvmNdkDir
        } else {
            Write-Warn "无法在 NDK 副本中定位 clang 目录，OLLVM 未集成"
        }
    } else {
        Write-Warn "无法定位 NDK clang 目录，OLLVM 未集成到 NDK"
    }

    Write-Success "OLLVM 配置完成"
    return $NdkPath
}

# ==================== 修复 OLLVM-NDK 库路径不匹配 ====================
function Fix-OllvmLibPath {
    param([string]$NdkPath)

    # 动态探测 prebuilt 目录（支持不同架构）
    $prebuiltDir = Get-ChildItem "$NdkPath\toolchains\llvm\prebuilt" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $prebuiltDir) {
        Write-Warn "未找到 NDK prebuilt 目录，跳过库路径修复"
        return
    }

    $libDir = "$($prebuiltDir.FullName)\lib"
    $lib64Dir = "$($prebuiltDir.FullName)\lib64"

    $realVer = $null
    if (Test-Path $lib64Dir) {
        $realVer = Get-ChildItem $lib64Dir -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match '^\d+\.' } | Select-Object -First 1 -ExpandProperty Name
    }

    if (-not $realVer) {
        Write-Warn "未找到 NDK 的 clang 库版本目录，跳过库路径修复"
        return
    }

    $targetLink = "$libDir\clang\13.0.1"
    if (-not (Test-Path $targetLink)) {
        Write-Info "修复 OLLVM 版本号与 NDK 库路径不匹配..."
        New-Item -ItemType Directory -Force -Path "$libDir\clang" | Out-Null
        try {
            # Windows 上 Junction 不需要管理员权限（同一卷内）
            New-Item -ItemType Junction -Path $targetLink -Target "$lib64Dir\$realVer" | Out-Null
            Write-Success "已创建库路径 Junction: lib\clang\13.0.1 -> lib64\clang\$realVer"
        } catch {
            # 回退到完整复制
            Copy-Item "$lib64Dir\$realVer" $targetLink -Recurse -Force
            Write-Success "已复制库目录: lib\clang\13.0.1 <- lib64\clang\$realVer"
        }
    }
}

# ==================== 配置 dcc.cfg（原子写入） ====================
function Configure-DccCfg {
    param([string]$NdkPath, [bool]$OllvmEnable = $false)

    # 轮转旧备份
    Rotate-Backups "." "dcc.cfg.bak.*" 5
    $bakFile = "dcc.cfg.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item "dcc.cfg" $bakFile -ErrorAction SilentlyContinue

    $pyBool = if ($OllvmEnable) { "True" } else { "False" }
    $escapedNdk = $NdkPath.Replace('\', '\\')

    # 原子写入：先写入临时文件，再重命名
    $tmpCfg = "dcc.cfg.tmp.$PID"

    python -c @"
import json, sys, os
try:
    with open('dcc.cfg', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    old_ndk = cfg.get('ndk_dir', '未设置')
    cfg['ndk_dir'] = r'$escapedNdk'
    if 'ollvm' not in cfg:
        cfg['ollvm'] = {
            'enable': False,
            'flags': '-fvisibility=hidden -mllvm -fla -mllvm -split -mllvm -split_num=5 -mllvm -sub -mllvm -sub_loop=5 -mllvm -sobf -mllvm -bcf_loop=5 -mllvm -bcf_prob=100'
        }
    cfg['ollvm']['enable'] = $pyBool
    with open(r'$tmpCfg', 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
        f.write('\n')
    print(f'[INFO] dcc.cfg 已更新')
    print(f'  ndk_dir: {cfg["ndk_dir"]}')
    print(f'  ollvm.enable: {cfg["ollvm"]["enable"]}')
    if old_ndk != cfg['ndk_dir']:
        print(f'  原 ndk_dir: {old_ndk}')
except Exception as e:
    print(f'[ERROR] 修改 dcc.cfg 失败: {e}', file=sys.stderr)
    sys.exit(1)
"@

    if ($LASTEXITCODE -ne 0) { Write-ErrorX "dcc.cfg 更新失败" }

    # 原子替换
    Move-Item $tmpCfg "dcc.cfg" -Force
    Write-Success "dcc.cfg 配置完成"
}

# ==================== 最终验证 ====================
function Test-Final {
    Write-Info "执行最终验证..."
    $errors = @()

    try { python -c "import json; json.load(open('dcc.cfg'))" } catch { $errors += "dcc.cfg JSON 格式损坏" }
    if (-not (Test-Path ".venv\Scripts\python.exe")) { $errors += "Python 虚拟环境不完整" }

    $ndk = python -c "import json; print(json.load(open('dcc.cfg'))['ndk_dir'])" 2>$null
    if (-not $ndk -or -not (Test-Path "$ndk\ndk-build.cmd")) { 
        $errors += "NDK 路径错误或 ndk-build 不可执行: $($ndk -or '(空)')" 
    }
    if (-not (Test-Path "tools\apktool.jar")) { $errors += "tools\apktool.jar 缺失" }

    if ($errors.Count -gt 0) {
        Write-ErrorX "验证失败:`n  - $($errors -join "`n  - ")"
    }
    Write-Success "所有验证通过！"
}

# ==================== 主流程 ====================
function Main {
    Assert-Admin

    if (-not (Test-Path "dcc.py")) {
        Write-Warn "未检测到 dcc.py，请确保在 Dex2C-New 仓库根目录运行"
        $cont = Read-Host "是否继续? (y/N)"
        if ($cont -notmatch '^[Yy]') { exit 0 }
    }

    Write-Info "请选择安装模式:"
    Write-Host "  [1] 普通模式 - 下载标准 NDK（推荐，稳定）"
    Write-Host "  [2] OLLVM 模式 - 下载兼容 NDK + 编译 OLLVM 并集成（耗时较长，需要 4GB+ 内存和 Visual Studio）"
    $choice = Read-Host "输入 1 或 2 (默认 1)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    while ($choice -notin @("1","2")) {
        $choice = Read-Host "输入 1 或 2 (默认 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    }

    $enableOllvm = $false
    $ndkVersion = "r27c"
    if ($choice -eq "2") {
        $enableOllvm = $true
        $ndkVersion = "r25c"
        Write-Info "已选择 OLLVM 模式（NDK $ndkVersion + OLLVM $OLLVM_BRANCH）"
    } else {
        Write-Info "已选择普通模式（NDK $ndkVersion）"
    }

    Test-RepoIntegrity
    Install-SystemDeps

    $venvPath = Install-PythonDeps "requirements.txt" ".venv"
    $ndkPath = Install-NDK $ndkVersion "$env:USERPROFILE\Android\Sdk\ndk"

    if ($enableOllvm) {
        $ndkPath = Install-Ollvm $ndkPath
    }

    Configure-DccCfg $ndkPath $enableOllvm
    Test-Final

    Write-Success "========== Dex2C-New 环境配置完成 =========="
    Write-Host ""
    Write-Host "使用步骤:"
    Write-Host "  1. .venv\Scripts\Activate.ps1"
    Write-Host "  2. 编辑 filter.txt 配置需要保护的方法"
    Write-Host "  3. python dcc.py -a input.apk -o output.apk"
    Write-Host ""
    Write-Host "NDK 路径:  $ndkPath"
    Write-Host "虚拟环境:  $venvPath"
    Write-Host "配置文件:  $(Resolve-Path dcc.cfg)"
    if ($enableOllvm) { 
        Write-Host "OLLVM:     已启用（使用隔离 NDK 副本，不影响原始 NDK）" 
    }
}

Main
