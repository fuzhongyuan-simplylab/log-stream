# 移动日志

macOS 上的 Android 和 iOS 日志查看工具。可以发现已连接的模拟器和真机，实时显示日志，并支持按文本或正则过滤、暂停、清空和导出。

Android 通过 adb 读取 logcat。iOS 通过 Xcode 读取日志：模拟器使用 `simctl` 的 `log stream`，真机使用系统控制台同一套实时流。两边都按关键字过滤，不按应用过滤。有关键字时，过滤在设备上完成，只有匹配的日志会传过来。

需要 macOS 14 及以上和 Swift 6。Android 需要本机可用的 adb（Android SDK platform-tools）。iOS 需要 Xcode，并且 `xcode-select` 指向它。真机需要用数据线连接，并在设备上信任这台 Mac。

`print()` 只会出现在 Xcode 调试器里。这里能看到 `os_log`、`Logger` 和 `NSLog`。

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

生成 `dist/移动日志.app`。脚本会做 release 构建、组装应用包并做临时签名。

**安装**：

```sh
cp -R "dist/移动日志.app" /Applications/
open "/Applications/移动日志.app"
```
