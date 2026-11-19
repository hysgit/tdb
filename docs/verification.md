# Tdb 验证记录

日期：2026-11-19。应用名称 `Tdb`，包标识 `com.hysgit.tdb`，版本 `1.0.0+1`。

## 已完成

- `flutter analyze`：No issues found。
- `flutter test`：50 项全部通过。字幕 9、AB 9、播放器服务 11、界面 6、存档 5、Wi-Fi 10。
- `flutter build apk --debug`：成功。Windows Kotlin 增量缓存有跨盘问题，本工程设置 `kotlin.incremental=false`，使用完整编译。
- 从最终 APK 的 `aapt dump badging` 核验：`application-label='Tdb'`、`name='com.hysgit.tdb'`、`versionName='1.0.0'`、`versionCode='1'`、min SDK 24、target SDK 36。
- 本地安装包 `dist/Tdb-1.0.0-1-debug.apk`，175,793,627 字节；SHA-256：`9d94a037806c0c34a59b6901274291b867ee5d8e56f6797abe3e6d4308f00f00`。调试包包含调试引擎，体积不代表 iOS 发布包。

## 测试重点

1. AB 在越过 B 和文件末尾时的正确暂停/回跳，间隔内暂停、跳转、切文件及改范围不恢复旧播放。
2. LRC offset、多时间标签，SRT/VTT 多行，原 IPA JSON，自有 JSON 往返，以及纯文本的推定时间标记。
3. 320×568 与 390×844 的界面布局，收藏持久化回调，听写跨空隙保留答案，字幕编辑与非法时间拒绝。
4. 100 次连续存档调用的顺序和快照隔离、损坏回退、写入失败后恢复、同名并发导入。
5. Wi-Fi 临时文件隔离、中断清理、令牌失效、等待导入成功后才响应、真实 257 MiB 分块请求不能绕过上限。

## 未确认

Android 模拟器当前 `-accel-check` 报硬件加速不可用；软件模式尝试后 adb 仍为 offline。未能安装运行本次 APK，不能宣称 Android 真机或模拟器端到端通过。测试中的播放器使用替身，录音权限、音视频硬件解码、后台播放和系统音频中断仍需手机验收。

Windows 未构建 iOS IPA。已配置 Codemagic iOS 工作流，但当前浏览器控制进程初始化失败；TestFlight 尚未上传或分发。详见 [云发布说明](cloud-release.md)。
