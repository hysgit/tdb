# Tdb

使用 Flutter 重建的本地音视频听读应用。Android / iOS 包标识均为 `com.hysgit.tdb`，显示名称为 `Tdb`，版本 `1.0.0+1`。

## 已实现

- 导入音视频，建立文件夹，搜索、排序、重命名、移动和删除应用内副本。
- 真实音频及视频播放、0.1–3 倍速、音量、快进快退、进度恢复、定时暂停。
- AB 复读：有限/无限次数、复读间隔、逐句播放；暂停、拖动进度和切文件可取消等待中的旧循环。
- UTF-8 JSON / LRC / SRT / VTT / TXT 字幕、双语显示、定位、收藏、编辑正文及时间。纯文本按每句 5 秒推定，界面明确标识，支持手动校准。
- 听写隐藏原文、逐句核对、词级文本匹配度；麦克风跟读录音、保存和回听。
- 同一局域网通过浏览器传入媒体或字幕。随机令牌、256 MiB 流式上限、关闭传输窗口后地址失效。
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

iOS Release 已在 macOS 云端编译通过：[成功构建](https://github.com/hysgit/tdb/actions/runs/44524879211)。随后 [Codemagic 签名构建](https://codemagic.io/app/6afef749aec4811f2d5c1021/build/6afefe358f52ca275128e2d1) 已生成 App Store 签名 IPA 并进入上传阶段；Apple 最终处理和 TestFlight 分发结果仍待核验。

## 还原依据与边界

[静态分析报告](docs/2026-11-19_逆向-听读宝-report.md)记录 IPA SHA-256、界面及配置证据和覆盖范围。原版主程序有 App Store 加密标记 `cryptid=1`；此工程是独立重建，不是恢复原始源码。

尚未重建：第三方云盘、购买、语音识别/发音评分、自动分句/翻译、提醒通知、音频合成、分享扩展及 Siri。没有原版运行录像，因此像素和动态交互的一致性未确认。后台音频、系统中断、麦克风和原生媒体解码仍需在实际手机验收；自动化中的播放服务和界面测试使用可控替身，不等同于真机通过。
