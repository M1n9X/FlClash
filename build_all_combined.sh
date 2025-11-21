#!/bin/bash

# FlClash 一键构建脚本 - Android & macOS (APP + DMG)
# 作者: Claude
# 日期: 2025-11-21

set -e  # 遇到错误时退出

echo "=== FlClash 一键构建脚本 ==="
echo "开始构建 Android APK 和 macOS (APP + DMG)..."

# 检查必要工具
echo "检查必要工具..."
if ! command -v flutter &> /dev/null; then
    echo "错误: Flutter 未安装或不在 PATH 中"
    exit 1
fi

if ! command -v dart &> /dev/null; then
    echo "错误: Dart 未安装或不在 PATH 中"
    exit 1
fi

if ! command -v go &> /dev/null; then
    echo "错误: Go 未安装或不在 PATH 中"
    exit 1
fi

# 检查/设置 Android NDK 路径，避免 Dart 构建核心库时失败
echo "检查 Android NDK..."
ensure_android_ndk() {
    # 优先使用已设置的环境变量
    for candidate in "$ANDROID_NDK" "$ANDROID_NDK_HOME" "$ANDROID_NDK_ROOT"; do
        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
            ANDROID_NDK="$candidate"
            break
        fi
    done

    local props_file="android/local.properties"
    local sdk_dir ndk_dir

    if [ -z "$ANDROID_NDK" ] && [ -f "$props_file" ]; then
        ndk_dir=$(sed -n 's/^ndk.dir=//p' "$props_file" | head -n 1 | tr -d '\r' | sed 's#\\\\#/#g')
        sdk_dir=$(sed -n 's/^sdk.dir=//p' "$props_file" | head -n 1 | tr -d '\r' | sed 's#\\\\#/#g')

        # 如果未显式指定 ndk.dir，则尝试从 sdk.dir 下选择最新的 NDK 版本
        if [ -z "$ndk_dir" ] && [ -n "$sdk_dir" ] && [ -d "$sdk_dir/ndk" ]; then
            ndk_dir=$(find "$sdk_dir/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -n 1)
        fi

        if [ -n "$sdk_dir" ] && [ -d "$sdk_dir" ] && [ -z "$ANDROID_SDK_ROOT" ] && [ -z "$ANDROID_HOME" ]; then
            export ANDROID_SDK_ROOT="$sdk_dir"
        fi

        if [ -n "$ndk_dir" ] && [ -d "$ndk_dir" ]; then
            ANDROID_NDK="$ndk_dir"
        fi
    fi

    # 常见路径兜底
    if [ -z "$ANDROID_NDK" ]; then
        local candidate_ndk
        for sdk_guess in "$ANDROID_SDK_ROOT" "$ANDROID_HOME" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
            if [ -n "$sdk_guess" ] && [ -d "$sdk_guess/ndk" ]; then
                candidate_ndk=$(find "$sdk_guess/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -n 1)
                if [ -n "$candidate_ndk" ] && [ -d "$candidate_ndk" ]; then
                    ANDROID_NDK="$candidate_ndk"
                    [ -z "$ANDROID_SDK_ROOT" ] && export ANDROID_SDK_ROOT="$sdk_guess"
                    break
                fi
            fi
        done
    fi

    if [ -z "$ANDROID_NDK" ]; then
        echo "错误: 未找到 Android NDK，请设置 ANDROID_NDK 或在 android/local.properties 中配置 sdk.dir/ndk.dir"
        exit 1
    fi

    export ANDROID_NDK
    echo "✓ ANDROID_NDK 设为: $ANDROID_NDK"
}

ensure_android_ndk

echo "✓ 所有必要工具都已安装"

# 使用兼容的 macOS 部署版本（默认与 Podfile 一致，可通过环境变量覆盖）
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-10.14.6}

# 获取项目依赖
echo "获取项目依赖..."
flutter pub get
dart pub get

# 构建前清理
echo "清理之前的构建文件..."
flutter clean

# 初始化子模块
echo "初始化子模块..."
git submodule update --init --recursive

# 构建 macOS 核心库
echo "构建 macOS 核心库..."
dart run setup.dart macos --arch arm64 --out core
dart run setup.dart macos --arch amd64 --out core

# 构建 Android 核心库（如果失败则跳过）
echo "构建 Android 核心库..."
if dart run setup.dart android --arch arm64 --out core; then
    dart run setup.dart android --arch arm --out core
    dart run setup.dart android --arch amd64 --out core
    echo "✓ Android 核心库构建成功"
else
    echo "⚠ Android 核心库构建失败，但将继续构建 APK（可能使用预构建的核心）"
fi

# 构建 Android APK
echo "构建 Android APK..."
flutter build apk --release

# 构建 macOS 应用
echo "构建 macOS 应用..."
flutter build macos --release

# 创建 DMG 安装包
echo "创建 DMG 安装包..."
mkdir -p dist

if [ -d "build/macos/Build/Products/Release/FlClash.app" ]; then
    # 使用 hdiutil 创建 DMG
    hdiutil create -volname "FlClash" -srcfolder "build/macos/Build/Products/Release/FlClash.app" -ov -format UDZO "dist/FlClash.dmg"
    echo "✓ DMG 创建成功: dist/FlClash.dmg"
else
    echo "错误: macOS 应用程序未找到"
    exit 1
fi

echo "✓ 所有构建任务完成!"
echo ""
echo "构建产物位置:"
echo "  Android APK : build/app/outputs/flutter-apk/app-release.apk"
echo "  macOS App   : build/macos/Build/Products/Release/FlClash.app"
echo "  macOS DMG   : dist/FlClash.dmg"
echo ""
echo "构建完成！"
