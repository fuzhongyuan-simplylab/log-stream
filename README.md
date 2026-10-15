# Android 日志

macOS 上的 Android 日志查看工具。通过 adb 发现已连接的模拟器和真机，实时显示 logcat，并支持按文本或正则过滤、暂停、清空和导出日志。

需要 macOS 14 及以上、Swift 6，以及本机可用的 adb（Android SDK platform-tools）。

## 常用命令

在项目根目录执行。

**启动**（调试运行）：

```sh
swift run
```

**构建**：

```sh
swift build
swift build -c release
```

**本地打包**：

```sh
./scripts/build-app.sh
```

生成 `dist/Android 日志.app`。脚本会做 release 构建、组装应用包并做临时签名。

**安装**：

```sh
cp -R "dist/Android 日志.app" /Applications/
open "/Applications/Android 日志.app"
```
