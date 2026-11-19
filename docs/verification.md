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

Windows 未构建 iOS IPA。随后 GitHub 完成未签名原生编译，Codemagic 完成签名、上传和 Apple 后处理；TestFlight 分发已核验，详见下文。尚未在受邀手机实际安装运行，不能将分发成功等同于真机功能验收。

## iOS 云端编译成功

- 运行：<https://github.com/hysgit/tdb/actions/runs/44524879211>，结果 `success`。
- 编译提交：`6180c773dc4626332df55ea92eedfb35bf923f18`。
- 环境：macOS 15、Xcode 26.3、Flutter 3.50.0。镜像默认 Xcode 16.4 与视频插件新版 AVFoundation API 不兼容，已通过显式选择 26.3 修复。
- 云端依赖解析、`flutter analyze`、`flutter test`、`flutter build ios --release --no-codesign` 及产物保存全部成功。
- 产物：`Tdb-iOS-unsigned-3`，GitHub artifact ID `14530095330`，13,331,311 字节；SHA-256：`58def59d4df070b2fad4697886a30eaa6554ac85de7340fe96a4c81f46455711`。
- 该产物为未签名 `.app` 的压缩包，证明 iOS 原生编译通过，不能作为 TestFlight 安装包。真机运行、签名、Apple 处理和分发仍未验证。

## 首次 App Store 签名构建（未分发）

- Apple App 记录已建立：`Tdb`，App ID `6836784026`，Bundle ID `com.hysgit.tdb`。
- 复用现有分发证书，创建并导入专用 App Store profile `tdb-appstore`，Codemagic 页面确认与已保存证书匹配。
- 经用户明确授权，既有 Developer 测试账号仅追加 Tdb 应用访问权限并加入 `Tdb 内测`；页面确认组内 1 名测试者。自动分发未来所有构建未启用。
- [Codemagic 构建 1](https://codemagic.io/app/6afef749aec4811f2d5c1021/build/6afefe358f52ca275128e2d1)，源码提交 `2c5de7f`，工作流 `Tdb iOS TestFlight`。
- 最终状态为 `finished with post-processing failed`。签名、检查与测试、归档及上传已完成；可见产物 `tingdubao.ipa [26.35 MB]`。
- 归档下载时控制连接超时；随后浏览器读操作持续报 `Debugger unattached`。未取得本地签名 IPA，不记录未核实的文件哈希。
- 上传日志确认 `UPLOAD SUCCEEDED with no errors, 1 warning`；警告为未来 SDK 要求。后处理 16 分 15 秒内未找到对应构建，具体 Apple 处理错误未取得。本次未分发。

## TestFlight 成功分发

- 源码提交：`67c91705e63104d6c56c963a553bb4c926fe4438`。通过项目级 CocoaPods 配置，仅编入实际使用的文档选择模块，关闭未使用的相册和音乐库模块。
- [GitHub 修复版验证](https://github.com/hysgit/tdb/actions/runs/44557270532)：检查、50 项测试和 iOS Release 编译全部成功。
- [Codemagic 构建 2](https://codemagic.io/app/6afef749aec4811f2d5c1021/build/6aff190f8f52ca275128eeb7)：`finished`；检查与测试 45 秒、IPA 归档 1 分 23 秒、上传 1 分 26 秒，Apple 后处理 3 分 44 秒。
- 签名产物：`tingdubao.ipa [25.22 MB]`。未下载到本地，不填报未核实的文件哈希。
- App Store Connect 页面确认：`Tdb 内测`，`Internal Group ∙ 1 Tester ∙ 1 Build`，`Build 1.0.0 (2)`，状态 `Testing`，有效期 90 天。Apple build ID：`fdbc70c9-d9b6-4459-94d9-a5691e6416d7`。
- 目标测试者状态 `Invited`；仅增加经用户批准的 Tdb Developer 应用访问权限，未新增管理员、证书或 API Key 权限。
- 本地凭证：`dist/Tdb-TestFlight-1.0.0-2.jpg`；本地进度：`dist/testflight-release-progress.json`。测试者地址和账号权限截图不提交仓库。
- 真机实际安装、录音权限和媒体播放仍待受邀账号验收。
