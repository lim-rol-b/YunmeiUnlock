# YunmeiUnlock

YunmeiUnlock 是一个非官方的云莓门禁 iOS 客户端。它通过用户自己的云莓账号获取获授权的门锁配置，并使用蓝牙发送开门指令。

## 功能

- 登录云莓账号并获取学校与门锁列表
- 将门锁配置保存在本机 Keychain
- 在 App 内手动或自动开门
- 通过快捷指令选择并打开指定门锁

## 隐私

账号和密码仅用于直接请求云莓服务。密码不会持久化，门锁配置保存在本机 Keychain。本项目不包含开发者账号、测试账号、门锁密钥或签名材料。详情见 [PRIVACY.md](PRIVACY.md)。

## 构建

1. 使用 Xcode 打开 `YunmeiUnlock.xcodeproj`。
2. 在 Signing & Capabilities 中选择自己的开发团队。
3. 如有需要，将 Bundle Identifier 修改为自己账号下的唯一值。
4. 连接 iPhone 后构建并安装。

仓库不提供任何人的开发者签名。未来如发布 IPA，将仅发布需要下载者自行签名的未签名版本。

## 来源与许可

登录接口流程、认证请求头、门锁数据解析与蓝牙开锁 payload 格式，基于 MIT 许可项目 [zxy19/yunmei_unintelligent](https://github.com/zxy19/yunmei_unintelligent) 的安卓实现重新以 Swift 编写。

[zxy19/yunmei_unintelligent_pwa](https://github.com/zxy19/yunmei_unintelligent_pwa) 作为相关 PWA 实现和功能参考。本项目未使用其第三方 HTTP 代理。

本项目是非官方客户端，与云莓智能及上述项目作者不存在官方隶属或合作关系。用户只能操作自己有权访问的账号和门锁。

项目采用 [MIT License](LICENSE)，第三方归属信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
