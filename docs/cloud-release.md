# Tdb 云构建与 TestFlight

用户指定沿用“重实现 gxtudo 应用与服务端”会话中的 Codemagic 路径。已核对该工程的 `codemagic.yaml`，当前工程提供独立 `tdb-ios-testflight` 和 `tdb-ios-simulator` 工作流。

## 身份

| 项目 | 值 |
|---|---|
| 显示名称 | Tdb |
| Bundle ID / Android applicationId | com.hysgit.tdb |
| 版本 | 1.0.0 |
| 本地构建号 | 1 |
| 云构建号 | Codemagic BUILD_NUMBER |
| Codemagic Apple 集成名 | tudo（沿用已有集成，需对新 App 有权限） |
| 预期内部测试组 | Tdb 内测 |

## 首次发布前配置

1. 在同一 Apple Developer 团队登记 `com.hysgit.tdb`，配置对应的 App Store 分发证书及 provisioning profile。
2. 在 App Store Connect 建立独立 App `Tdb`，选择该 Bundle ID，建立内部测试组 `Tdb 内测`，加入所需内部测试者。现有高效Todo的 App ID 和构建不能被此包复用。
3. 在 Codemagic 接入独立仓库 `https://github.com/hysgit/tdb.git` 的 `main` 分支，确保可使用 `tudo` 集成及此 Bundle ID 的签名资源。
4. 手动选择 `tdb-ios-testflight`，运行检查、测试、签名和 IPA 构建。该工作流上传到 App Store Connect 并指定内部测试组，与既有工程一致使用 `submit_to_testflight: false`，不自动提交外部测试的 Beta App Review，也不提交公开 App Store 审核。
5. 核对 Apple 处理完成、构建可用及组内构建关联。只有这些记录成功才可标记“已发布”。

若需先验证 iOS 编译，可运行不需要分发签名的 `tdb-ios-simulator`。所有密钥应留在 Codemagic 的安全配置中，不写入仓库。

## 本次状态

- 源码已推送至用户指定的独立仓库 `hysgit/tdb`，分支为 `main`。
- 浏览器控制不可用时，可由 `.github/workflows/ios-compile.yml` 使用 GitHub 的 macOS 云端执行检查、测试和 iOS 原生编译。生成的是未签名的 `.app` 压缩包，不能通过 TestFlight 安装；分发仍由 Codemagic 签名发布工作流负责。
- 工作流已写入并复用已核对的 Flutter / Xcode / CocoaPods 配置。
- 先前的 sandbox 启动错误已在用户授权后通过当前项目单目录所有者修复解决；未修改全局 sandbox 配置。
- 用户已明确指定并授权独立仓库 `https://github.com/hysgit/tdb.git`。远程检查未发现已有引用，本工程使用 `main` 分支；不再使用高效Todo仓库的独立分支。
- GitHub macOS 云构建已成功：`https://github.com/hysgit/tdb/actions/runs/44524879211`，编译提交 `6180c773dc4626332df55ea92eedfb35bf923f18`。检查、测试、iOS Release 原生编译和未签名产物保存全部成功。
- 初次原生编译错误来自镜像默认 Xcode 16.4 的 AVFoundation SDK 不识别视频插件使用的 `isolation` 参数；显式选择官方镜像已安装的 Xcode 26.3 后编译通过。具体产物身份见 [验证记录](verification.md)。
- Apple App 记录已创建：App ID `6836784026`；专用 profile `tdb-appstore` 已导入并匹配现有分发证书；`Tdb 内测` 已加入 1 名经用户授权的内部测试者，未启用未来构建自动分发。
- Codemagic App ID `6afef749aec4811f2d5c1021`；[签名构建 1](https://codemagic.io/app/6afef749aec4811f2d5c1021/build/6afefe358f52ca275128e2d1) 使用提交 `2c5de7f`，已生成 `tingdubao.ipa [26.35 MB]`，最后观察状态为 `publishing`。
- 归档下载超时后，浏览器控制连接持续报 `Debugger unattached`。Apple 上传完成、处理完成和最终内测分发仍未核验，不能据此文档声称已发布。
