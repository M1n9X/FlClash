# FlClash 一键构建脚本

提供一键构建脚本，用于快速构建 Android 和 macOS 版本的 FlClash。

## 脚本说明

### build_all_combined.sh
构建 Android APK 和 macOS 应用程序，并同时生成 APP 和 DMG 格式

**功能：**
- 清理之前的构建文件
- 初始化 Git 子模块
- 构建 macOS 核心库 (ARM64 和 x64)
- 构建 Android 核心库 (ARM64, ARM, x64)
- 构建 Android APK (release 版本)
- 构建 macOS 应用程序
- 创建 macOS DMG 安装包

## 使用方法

### 前提条件
确保已安装以下工具：
- Flutter SDK
- Dart SDK
- Go 语言环境
- CocoaPods (macOS)

### 运行脚本

```bash
# 构建所有平台并同时生成 APP 和 DMG
./build_all_combined.sh
```

## 输出文件位置

- **Android APK**: `build/app/outputs/flutter-apk/app-release.apk`
- **macOS App**: `build/macos/Build/Products/Release/FlClash.app`
- **macOS DMG**: `dist/FlClash.dmg`

## 注意事项

1. 首次运行时可能需要一些时间来下载依赖
2. macOS DMG 创建使用系统自带的 `hdiutil` 工具
3. 确保有足够的磁盘空间进行构建过程
4. 脚本会自动处理核心库的构建

## 自定义构建

如果需要修改构建参数，可以编辑脚本中的相应部分：
- 架构类型 (arm64, x64, arm)
- 构建模式 (release/debug)
- 输出路径等