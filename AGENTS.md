# 项目工作规则

## 项目状态

项目名称：Phone Photo Backup（手机照片备份）。目标是将手机里的照片和视频（USB 直连读取，或已导出的文件夹）备份到用户指定的本地位置；不上传云端。现有实现为 macOS 原生应用：Swift 6 + SwiftUI，最低 macOS 14，使用 Swift Package Manager 构建，需要完整 Xcode（已在 Xcode 27.2 验证；只装 Command Line Tools 的 Mac 上 SwiftUI 的 `@State` 曾无法编译）。

## 文档入口

- [当前进度与交接](handoff.md)：当前状态、阻碍和下一步。
- [架构说明](docs/architecture.md)：模块职责、边界和关键数据流。
- [决策记录](docs/decisions.md)：重要决策及原因。

## 目录约定

- `Sources/BackupCore/`：备份引擎（不依赖界面）。
- `Sources/PhonePhotoBackup/`：SwiftUI 应用界面与手机直连（ImageCaptureCore）。
- `Tests/BackupCoreTests/`：引擎测试（Swift Testing）。
- `Resources/`：Info.plist 与本地化字符串（en、zh-Hans）。
- `scripts/`：打包 `.app` 与生成图标的脚本。
- `docs/`：架构和重要决策等长期技术文档。

## 长期工作规则

1. 开始工作前阅读本文件和 `handoff.md`，按任务需要阅读架构与决策记录。
2. 以现有代码和已确认需求为依据；尚未实现或确定的内容必须明确标注。
3. 保持改动聚焦，避免无关重构。采用技术栈后，在本文件中补充准确的安装、运行和测试命令。
4. 实现行为变更时进行适当验证，并在交接中记录验证结果及未完成项。
5. 模块职责、边界或数据流变化时更新架构说明；重要技术选择在决策记录中说明原因。
6. 结束工作时更新 `handoff.md`，使其反映最新状态；长期规则保留在本文件，过程日志不在此累积。
7. 使用临时或模拟照片进行测试，不将私人照片、凭据或备份产物提交到仓库。

## 常用命令

在项目根目录执行：

```sh
git status --short
rg --files -g '!.git'
git diff
git diff --check
```

当前不需要第三方依赖。项目根目录执行：

```sh
swift test                      # 运行测试
scripts/build-app.sh            # 打包 build/Phone Photo Backup.app
swift run PhonePhotoBackup      # 开发时无 bundle 启动（英文界面）
```

界面状态写法：跨视图共享的状态放在 `BackupModel`（`@Observable`），视图私有的状态（拖放高亮、展开/折叠等）用标准 `@State`；应用入口用 `@State` 持有模型并通过 `.environment` 下发。新增界面文字时同步更新 `Resources/zh-Hans.lproj/Localizable.strings`。

`PPB_SNAPSHOT_DIR=<目录>` 环境变量会让应用对已保存的文件夹自动扫描并备份、把窗口截图写入该目录后退出，仅用于开发自检，且只能对临时模拟文件使用；此模式下不搜索手机，避免误读连接着的真实手机。测试必须使用临时模拟文件，不读取真实照片；手机直连的引擎逻辑用 `StagedBackupTests` 里的模拟设备测试，真机流程需由用户手动验收。
