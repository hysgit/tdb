# 听读宝 Flutter 重建分析范围

- 日期：2026-11-19。
- auth：用户提供自己的 IPA，说明源码丢失，并要求用 Flutter 重新实现。
- in_scope：`D:/ai/tingdubao/tingdubao-1133575767.ipa`；该包解压后的资源、配置、Mach-O 静态头及 load commands、已编译的 Interface Builder 资源；Flutter 独立重建。
- out_of_scope：其他应用、第三方账号与数据、云端写操作、支付交易；本次没有原应用运行观察。
- network_profile：本报告仅使用本地静态分析。未登录云盘、未调用云服务、未验证任何云端接口。
- artifact_handling：保留原 IPA；分析产物写入 `analysis/`。剩余 13 个 nib 以逐字节副本补充解码，原相对路径及 SHA-256 见 `analysis/ui-remainder-provenance.json`。
- success_boundary：可核实的包内身份、资源、UI 字段及局限均形成证据；实现覆盖和真机效果需由独立构建、测试及人工验收证明。

## 2026-11-20 补充范围

- current_reference：用户提供的 `dist/current-reference/current-operation.mp4`（104.633333 秒）；仅观察该录屏，不宣称代理运行过原应用。IPA 自带教程视频明确排除出当前 UI 还原依据。
- resource_recovery：用户授权针对同一 IPA 内的 `fs.zip` 做限定离线恢复；下载官方 bkcrack 到项目忽略目录、验证发布哈希、有限 JSON 明文格式假设、限时已知明文验证、解密副本 CRC 复验。没有运行密码字典或访问猜测后台。
- sensitive_data：不输出或提交恢复出的内部状态、密码或 OAuth 秘密；录屏内私人文件、统计值和历史记录不作为应用初始资料。
- output_boundary：原 IPA、原 `fs.zip` 保持只读；录屏、工具、解密文件和分析过程保存在本地 `dist/`，不提交这些原始产物。仅提交脱敏证据文档与独立 Flutter 实现。
