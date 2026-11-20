# Tdb

使用 Flutter 重建的本地音视频听读应用。Android / iOS 包标识均为 `com.hysgit.tdb`，显示名称为 `Tdb`，源码版本 `1.1.0+3`。云发布构建号由流水线分配。

当前界面与操作以用户提供的新版操作录屏为主要依据，IPA 自带的旧教程不作为当前版本的界面目标。见 [当前录屏与资源恢复依据](docs/2026-11-20_当前录屏与资源解密依据.md)。

## 已实现

- 文件、录音、更多、听力、我的五栏导航；播放器为独立页面，文件页保留迷你播放器。
- 导入音视频，建立多层文件夹，批量勾选、排序、重命名、移动和删除应用内副本。
- 真实音频及视频播放、0.1–5 倍速、自定义速度、音量、快进快退、进度恢复、定时暂停。
- AB 复读：有限/无限次数、复读间隔、逐句播放；暂停、拖动进度和切文件可取消等待中的旧循环。
- UTF-8 JSON / LRC / SRT / VTT / TXT 字幕、双语显示、定位、收藏、编辑正文及时间。纯文本按每句 5 秒推定，界面明确标识，支持手动校准。
- 听写隐藏原文、逐句核对、词级文本匹配度；麦克风独立录音、语句跟读录音、保存和原声对照回听。
- 从实际音频提取波形，拖动 AB 范围；静音分句、iOS 系统文件语音识别。离线识别取决于设备与语言支持，失败不会静默改用联网。
- 同一局域网通过浏览器传入媒体或字幕。优先使用真实 Wi-Fi 接口和短根地址；上传带会话令牌、256 MiB 流式上限，退出传输停止服务。独立字幕先保存，仅在同文件夹中唯一同名且无字幕时关联，不覆盖已编辑字幕。
- 学习时长、本地播放历史、收藏与单词本；iOS 系统查词、分享、提醒和 tdb 链接指令。定时播放需点击通知，不保证后台定点自动开播。
- iOS 音轨提取与保调变速，真实 AAC/M4A 及 MP3 编码后导入副本；组件许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 本地数据串行保存、前一代备份、损坏检测；原始导入文件不被移动或修改。

示例音视频及 23 句双语字幕来自用户提供的 IPA；它们供本地重建与验证使用。

## 运行与验证

使用 Flutter 3.50.0 / Dart 3.14.0，Android 构建需要 JDK 17+。当前 Windows SDK 路径：

```powershell
& 'D:\ai\gxtudo\.analysis\tools\flutter\bin\flutter.bat' pub get
& 'D:\ai\gxtudo\.analysis\tools\flutter\bin\flutter.bat' analyze
& 'D:\ai\gxtudo\.analysis\tools\flutter\bin\flutter.bat' test
$env:JAVA_HOME='C:\Users\hy\scoop\apps\temurin21-jdk\current'
$env:ANDROID_HOME='D:\Android\Sdk'
& 'D:\ai\gxtudo\.analysis\tools\flutter\bin\flutter.bat' build apk --debug
```

Android 调试包生成到 `build/app/outputs/flutter-apk/app-debug.apk`。iOS 部署目标为 15.0，云构建见 [发布说明](docs/cloud-release.md)。

iOS **1.0.0（2）已发布到 TestFlight 内部测试**：[Codemagic 成功构建](https://codemagic.io/app/6afef749aec4811f2d5c1021/build/6aff190f8f52ca275128eeb7)。App Store Connect 已确认“Tdb 内测”组中有 1 名测试者、1 个构建，版本状态为 `Testing`。受邀账号可在 TestFlight 接受邀请并安装。

## 还原依据与边界

[静态分析报告](docs/2026-11-19_逆向-听读宝-report.md)记录 IPA SHA-256、界面及配置证据和覆盖范围。原版主程序有 App Store 加密标记 `cryptid=1`；此工程是独立重建，不是恢复原始源码。

尚未恢复：原版在线听力目录与下载接口、跨设备同步协议、播客订阅服务、Apple Music 曲库直取、自动翻译、发音评分、购买、音频合成、分享扩展及 Siri。OneDrive、iCloud、NAS 使用系统“文件”已配置的位置，不内置其账号授权。相册视频目前先存储到“文件”再导入。

现版录屏没有演示的详情流程采用独立实现，不能声称逐像素一致。精听聚焦模式也尚未证明等同于原版精听训练。后台音频、系统中断、麦克风、系统识别和原生媒体处理仍需实际手机验收；受控播放替身测试、Windows LAN 测试与 iOS 模拟器验证分别记录，不能相互替代。
