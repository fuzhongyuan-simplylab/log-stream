# Logstream

macOS 上的 Android 和 iOS 日志查看工具。可以发现已连接的模拟器和真机，实时显示日志，并支持按文本或正则过滤、暂停、清空和导出。

窗口左侧切换 Android / iOS，并列出虚拟机（或模拟器）和真机。选「全部设备」时并排查看，列多了可以横向滚动；点某一台则只看它。每台设备独立记录、暂停和跟随最新日志。

## 功能

- **实时日志**。设备在线后自动开始记录。第一次连上会带上近期缓冲。勾选「实时」时视图停在最新一行；向上滚动会单独关掉这台设备的实时跟随，滚回底部会重新打开。工具栏的「实时」一次作用于当前平台的全部设备。
- **过滤**。顶部输入关键字后点「应用」，或在输入框里按回车。文本模式不区分大小写，正则模式区分大小写。正则不合法时无法应用。有关键字时，过滤在设备上完成，只有匹配的日志会传过来。应用新条件会清空已显示的日志，再重新抓取。留空则显示全部。过滤条件和当前平台会记住，下次打开仍在。
- **窗口内搜索**。在某台设备的日志上按 `⌘F`，只在已经显示的内容里查找，抓取条件不变。文本模式不区分大小写，正则模式区分大小写。`⌘G` 下一条，`⇧⌘G` 上一条，`Esc` 关闭搜索。
- **暂停和开始**。暂停后已有日志保留，暂停期间的日志不会补上。再开始时从当前时刻继续。侧边栏右键或设备标题栏可以单独操作一台；在「全部设备」视图里，工具栏的「开始」「暂停」作用于当前平台的全部在线设备。
- **清空**。Android 会执行 `logcat -c`，清掉这台设备的 logcat 缓冲。iOS 只清掉窗口里已经显示的行，设备上的系统日志还在。
- **排序**。真机和模拟器可以分别按名称、系统版本、连接标识排序。Android 还可以按 API。升序和降序都会记住。侧边栏和全部设备视图用同一顺序。Android 的连接标识是模拟器端口或真机序列号，iOS 是 UDID。
- **导出**。可以复制到剪贴板，或存成 txt。多台设备可以合并成一个文件，也可以每台一个文件。单台设备的文件名是「设备名-序列号.txt」，合并文件名是 `Logstream-日期时间.txt`。导出内容包含设备名称、类型、序列号、系统版本、状态、过滤条件和当时窗口里的日志。
- **iOS 调试级别**。每台 iOS 设备有「调试」开关，选择会记住。默认只显示 Default、Info、Error 和 Fault；打开后额外包含 Debug。切换后会清空这台设备窗口里的日志并重新抓取。

每台设备在窗口里最多保留 10,000 行，更早的行会被丢掉。点进某一台时，工具栏的批量开始、暂停、清空和导出不可用，改用这台设备自己的按钮。

## 日志从哪来

Android 使用本机的 `adb logcat -v time`。模拟器和真机走同一条路径。`adb devices` 能看到的设备都会列出来，包括未授权、离线和无权限；只有状态为在线的设备会读日志。

iOS 使用 Xcode。模拟器走 `xcrun simctl spawn … log stream`，只列出已经启动的模拟器。真机走系统控制台同一套实时流，需要用数据线连接，并在设备上信任这台 Mac。

`print()` 只会出现在 Xcode 调试器里。这里能看到 `os_log`、`Logger` 和 `NSLog`。

关键字匹配日志内容。Android 用 `logcat -e` 做整行匹配。iOS 在设备上匹配消息、进程名、subsystem 和 category。

## 环境

- macOS 14 及以上
- Swift 6（用 `swift run` 或打包脚本构建时需要）
- Android：本机可用的 adb（Android SDK platform-tools）。查找顺序是 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`~/Library/Android/sdk/platform-tools/adb`、`/opt/homebrew/bin/adb`、`/usr/local/bin/adb`，以及 `PATH` 里的 `adb`。找不到时窗口会提示。鼠标停在状态栏上可以看到实际使用的 adb 路径。
- iOS：已安装 Xcode，并且 `xcode-select` 指向它。程序通过 `/usr/bin/xcrun` 调用。

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

生成 `dist/Logstream.app`。脚本会做 release 构建、组装应用包并做临时签名。

**安装**：

```sh
cp -R "dist/Logstream.app" /Applications/
open "/Applications/Logstream.app"
```

## 快捷键

| 按键 | 作用 |
| --- | --- |
| `⌘R` | 刷新设备 |
| `⇧⌘⌫` | 清空当前平台全部在线设备的日志（在全部设备视图里） |
| `⌘F` | 打开或关闭当前日志的搜索 |
| `⌘G` | 下一条匹配 |
| `⇧⌘G` | 上一条匹配 |
| `Esc` | 关闭搜索 |

## 项目结构

```
Package.swift                 Swift 包定义，可执行目标 MobileLogTools
Resources/Info.plist          应用名 Logstream，最低系统 macOS 14
scripts/build-app.sh          打出 dist/Logstream.app
Sources/MobileLogTools/       界面、设备发现、日志流和导出
```

这是一个 Swift Package 可执行程序，没有 Xcode 工程。应用显示名是 Logstream，包标识是 `local.mobile-log-tools`。
