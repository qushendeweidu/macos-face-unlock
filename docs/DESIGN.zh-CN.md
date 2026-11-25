# FaceUnlock — macOS 人脸解锁 App 说明文档

> 开发说明：公开版 App 文件名为 `FaceUnlock.app`。本地调试时曾临时使用 `FaceUnlock.app` 规避 macOS 菜单栏的旧路径隐藏状态，本文档已统一为 `FaceUnlock.app`。

## 一、项目目标

做一个最轻量、最贴合 macOS 生态的菜单栏人脸解锁工具：

- 纯 Swift + AppKit + 系统框架，零第三方运行时、零内置模型
- 登录后自启（SMAppService），空闲不占 CPU，摄像头按需启动
- 锁屏/唤醒时自动识别人脸，匹配成功后在锁屏自动输入登录密码
- 只保存人脸特征向量，不保存任何画面

## 二、已核实的技术前提

1. 截至 2026 年没有任何 Mac 配备 Face ID 硬件，Mac 只有普通 RGB 摄像头，没有结构光/深度传感器。本项目是 2D 人脸识别，安全性不等同于 iPhone Face ID / Touch ID。
2. macOS 未开放第三方 App 授权系统登录的 API。唯一可行路径是：加密保存登录密码，识别成功后用辅助功能权限在锁屏模拟键盘输入。参考实现：Glance（MIT）。
3. 「开机自启」实际是「登录后自启」。真正的登录前启动需要 LaunchDaemon，但那个阶段拿不到摄像头和用户钥匙串，本项目不采用。

## 三、技术方案

| 模块 | 选型 | 说明 |
|---|---|---|
| 语言/UI | Swift 5 模式 + AppKit | 菜单栏 NSStatusItem + LSUIElement，不进 Dock |
| 相机 | AVFoundation，640×480 | 按需 startRunning，扫描结束立即 stopRunning |
| 人脸检测 | Vision DetectFaceRectanglesRequest / DetectFaceLandmarksRequest | macOS 15+，系统预训练模型，自动调度 ANE/GPU |
| 人脸特征 | Vision GenerateImageFeaturePrintRequest | 零模型文件；对齐裁剪后取特征向量 |
| 相似度 | 特征向量 L2 距离 + 自动校准阈值 | 录入时用样本间距离自动给出初始阈值 |
| 模板存储 | CryptoKit AES-GCM，密钥同目录 | `~/Library/Application Support/FaceUnlock`，权限 0600 |
| 密码存储 | AES-GCM 密文 + 本地密钥 | 不落明文、不写钥匙串 |
| 配置存储 | Application Support/FaceUnlock/settings.json | 不使用 UserDefaults |
| 自启动 | SMAppService.mainApp | macOS 13+，无需 LaunchAgent plist |
| 锁屏触发 | DistributedNotificationCenter + NSWorkspace | com.apple.screenIsLocked 为非公开通知，需容错 |
| 解锁动作 | CGEvent 键盘注入 + 辅助功能权限 | 默认关闭，需用户显式开启 |
| 日志 | ~/Library/Logs/FaceUnlock/FaceUnlock.log | 便于验证锁屏阶段行为 |

## 三-1、标准数据目录

```text
/Applications/FaceUnlock.app           # 签名包，运行期不写入

~/Library/Application Support/FaceUnlock/
├── key.bin                        # AES-GCM 密钥（0600）
├── profile.bin                    # 人脸特征模板（AES-GCM 密文）
├── credential.bin                 # 登录密码（AES-GCM 密文）
└── settings.json                  # 开关配置

~/Library/Logs/FaceUnlock/
└── FaceUnlock.log
```

- App 包保持完整签名，数据写入标准位置，避免破坏封条；macOS 27 的 TCC 会拒绝为封条损坏的 App 授予无障碍权限。
- 代价：密钥与密文放在一起，加密只能防止明文直读，不能防御本机上有权限的进程。
- 菜单「打开数据目录」可直接验证上述文件。
- 菜单「清除全部数据并退出」会删除 Application Support、Logs、开机自启注册，并清理早期版本残留。
- 卸载：先执行「清除全部数据并退出」，再把 `/Applications/FaceUnlock.app` 拖进废纸篓。
- TCC 摄像头/无障碍记录属于系统数据库，卸载 App 后如仍显示条目，需在系统设置中手动移除。

## 四、安全边界（必须明确）

- 2D 摄像头无法可靠防住视频回放，只能做基础活体约束（本版要求画面中只有一张脸、人脸尺寸达标、连续多帧匹配）。
- 开启自动输入后，登录密码必须能被 App 在锁屏状态读取，这是方案本身的固有风险。
- 因此提供两级开关：先「试运行」（只识别不输入），确认稳定后再开启「自动输入密码」。
- 不做静默尝试：每次锁屏最多尝试若干帧，失败即停止，不循环刷脸。

## 五、里程碑

1. M1 工程骨架：SwiftPM、Info.plist、打包脚本、菜单栏常驻
2. M2 识别链路：相机采集、Vision 检测、特征向量、录入与测试窗口
3. M3 锁屏链路：锁屏监听、试运行识别、日志验证
4. M4 解锁链路：密码钥匙串、CGEvent 输入、自动解锁
5. M5 体验收尾：开机自启、权限状态、阈值校准、资源测量

## 六、进度记录

| 日期 | 事项 | 结果 |
|---|---|---|
| 2026-11-25 | 联网核实技术栈与 Mac 硬件限制 | 完成，确认无 Face ID 硬件、无第三方登录授权 API |
| 2026-11-25 | 确定方案：真锁屏解锁 + 纯 Vision + 纯菜单栏 | 完成 |
| 2026-11-25 | 使用 swiftc 类型检查验证 Vision / Accessibility / CGSession API 签名 | 通过 |
| 2026-11-25 | 搭建 M1 工程骨架 | 完成，`swift build -c release` 通过 |
| 2026-11-25 | 改为全包内存储（Data 目录 + 包内配置/日志） | 完成，启动验证未产生 ~/Library 文件 |
| 2026-11-25 | 打包 App 并首次启动 | 完成，包体积约 384KB，日志写入 Contents/Data/Logs |
| 2026-11-25 | 录入 / 测试 / 锁屏 / 密码输入链路 | 代码完成，待真机交互验证 |
| 2026-11-25 | 轻量化测量 | 包体积 388KB，空闲内存约 42MB，空闲 CPU 0% |
| 2026-11-25 | 外部残留检查 | ~/Library 下无 Preferences / Caches / Saved State / Logs 文件 |
| 2026-11-25 | 改为标准 macOS 结构 | App 在 `/Applications/FaceUnlock.app`，数据在 Application Support，日志在 ~/Library/Logs |
| 2026-11-25 | 解决无障碍无法授权 | 确认包内写数据破坏签名封条，数据移出 App 包后 `codesign --verify` 通过 |
| 2026-11-25 | 解决菜单栏图标不显示 | macOS 记住旧路径为隐藏，改用全新顶层路径 `/Applications/FaceUnlock.app` |
| 2026-11-25 | 菜单栏图标 3 秒自动隐藏 | 已验证：t=2s 显示，t=5s 隐藏 |
| 2026-11-25 | 新增 App 图标与 DMG 图标 | 完成，1024px 透明圆角图标、AppIcon.icns，版本 0.1.1 |
| 2026-11-25 | 优化 DMG 打包 | 完成，卷图标 + Applications 快捷方式，发布 v0.1.1 |

## 七、运行与验证

```bash
./scripts/build_app.sh
cp -R dist/FaceUnlock.app /Applications/
open /Applications/FaceUnlock.app
```

安装位置：`/Applications/FaceUnlock.app`。

- 数据：`~/Library/Application Support/FaceUnlock`
- 日志：`~/Library/Logs/FaceUnlock/FaceUnlock.log`
- App 包运行期只读，签名封条保持有效

菜单栏图标行为：

- 锁屏、扫描、唤醒时显示
- 解锁后 3 秒内未点击就自动隐藏
- 想让它回来：重新打开 App，或锁屏再解锁
- 可按住 Command 拖动图标到想要的位置，系统会记住

验证顺序：

1. 菜单栏出现 faceid 图标 → 「录入人脸…」→ 授予摄像头权限 → 缓慢左右转头采集 30 帧
2. 「测试识别…」→ 观察距离值，必要时用当前距离校准阈值
3. 「锁屏自动识别」打开 → 锁定屏幕（Control+Command+Q）→ 查看 `~/Library/Logs/FaceUnlock/FaceUnlock.log` 是否记录扫描与匹配
4. 「设置登录密码…」→ 在 **隐私与安全 → 无障碍** 中授权 → 「自动输入密码」打开 → 再锁屏验证真实解锁
5. 「打开数据目录」确认标准位置的模板、密码密文、配置和日志

## 七-1、卸载

1. 菜单「清除全部数据并退出…」（删 Application Support、Logs、开机自启注册、旧版残留）
2. 把 `/Applications/FaceUnlock.app` 拖进废纸篓
3. 如系统设置里仍残留摄像头/无障碍条目，手动点减号移除

## 八、已知限制

- 刘海/外接显示器切换后相机可能变化，本版固定使用系统默认摄像头。
- 屏幕锁定状态通过 CGSessionCopyCurrentDictionary 判断，属于半公开 API。
- App 使用 ad-hoc 签名，重新编译后 TCC 权限需要重新授予。
- 如需长期迭代，建议配置本地自签名证书，让签名标识保持稳定，避免每次重授权。
- 纯 Vision 特征不是人脸专用模型，阈值需按本人实际环境校准。
