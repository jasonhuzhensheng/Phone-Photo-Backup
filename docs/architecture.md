# 架构说明

## 当前实现

项目是 macOS 原生桌面应用（Swift 6 + SwiftUI，最低 macOS 14）。来源有两种：通过 USB 直连的手机（iPhone/iPad，或 PTP 模式的安卓手机，经 ImageCaptureCore 读取），或已导出到电脑的文件夹；目标是另一个本地备份位置。程序不调用云服务，不转换媒体内容（对支持 HEIF 的设备请求原始 HEIC/HEVC 而非转码后的 JPEG/H.264），不修改或删除手机上的文件。

## 模块职责与数据流

| 模块 | 职责 | 边界 |
| --- | --- | --- |
| `Sources/BackupCore/BackupEngine.swift` | 路径校验、递归扫描、复制、SHA-256 校验、冲突版本处理、进度与取消 | 只写用户选定的目标目录；不修改或删除来源文件；不依赖界面 |
| `Sources/BackupCore/StagedBackup.swift` | 设备来源的备份：设备计划、设备路径清理、逐个取回文件到备份目录内的暂存区、核对大小、fsync、SHA-256、排他发布；已备份且大小一致的文件不再从设备读取 | 通过注入的 `Fetch` 闭包取文件，不依赖 ImageCaptureCore；暂存区 `.phone-photo-backup-staging` 用完即删 |
| `Sources/BackupCore/Manifest.swift` | 读写 `.phone-photo-backup.json`（schema 1，与旧 Python 版兼容） | 原子写入；无法读取或不匹配时在复制前中止 |
| `Sources/BackupCore/FileSystem.swift` | POSIX 辅助：`lstat`、排他创建、排他发布、元数据复制 | 不跟随符号链接 |
| `Sources/PhonePhotoBackup/DeviceBrowser.swift` | ImageCaptureCore：发现 USB 设备、打开会话、读取完整文件列表（含 Live Photo 视频等附属文件）、下载单个文件；手机锁定或断开时等待恢复并重读列表 | 只读设备；不删除、不上传 |
| `Sources/PhonePhotoBackup/BackupModel.swift` | `@MainActor @Observable` 状态：来源（文件夹或设备）选择与记忆、新接入的手机自动设为来源、扫描/备份任务、进度、取消、防休眠 | 在后台任务中调用引擎 |
| `Sources/PhonePhotoBackup/ContentView.swift` | SwiftUI 界面：来源行（菜单列出已连接手机或选择文件夹，支持拖放）、手机状态、状态面板、确认对话框、结果与错误列表 | 不含文件操作逻辑 |
| `Sources/PhonePhotoBackup/PhonePhotoBackupApp.swift` | 应用入口、单窗口、菜单与快捷键 | — |
| `Sources/PhonePhotoBackup/SelfCheck.swift` | 开发自检：设置 `PPB_SNAPSHOT_DIR` 时自动运行流程并保存窗口截图 | 默认不启用 |
| `Resources/`、`scripts/` | Info.plist、en/zh-Hans 本地化；打包 `.app`、生成图标 | — |
| `Tests/BackupCoreTests/` | 用临时模拟字节测试复制、跳过、冲突、清单、重叠路径、符号链接、元数据、取消；用模拟设备测试设备来源的复制、免重读、冲突、下载不完整/失败、取消与继续、路径清理 | 不访问私人照片或真实设备 |

流程：界面读取两个目录 → 引擎解析真实路径并验证源和目标不重叠（不区分大小写）→ 扫描普通文件并预览数量/体积 → 用户确认 → 对每个文件计算 SHA-256 → 分块写入 `.part` 临时文件并 `fsync` → 确认源文件大小/修改时间未变且哈希一致 → 复制权限、时间戳（纳秒）、创建日期、扩展属性 → 排他地发布到目标（`renamex_np(RENAME_EXCL)`，否则硬链接，再否则检查后重命名，以支持 exFAT）→ 最后原子更新清单。目标以来源目录名加 `_backup` 命名，保持相对目录结构。

设备来源流程：发现设备 → 打开会话（iPhone 会提示“信任此电脑”）→ 等待完整文件列表 → 按设备上的文件夹结构生成相对路径和计划（备份目录为 `<设备名>_backup`）→ 用户确认 → 对每个文件：若清单中已有相同大小的版本且备份副本仍在则跳过，否则下载到暂存区 → 核对大小与设备报告一致 → fsync → SHA-256 → 与文件夹来源相同的跳过/冲突规则 → 排他发布（同卷重命名）→ 最后原子更新清单。手机锁定或断开时下载在原地等待，恢复后重新读取文件列表并继续；用户可随时停止。

相同相对路径且哈希未变时跳过；若内容变化，则保留原文件并将新版本写为 `<名称>.conflict-<哈希前8位>.<扩展名>`。清单按相对路径追踪不同版本，不保存原始绝对路径。符号链接不会跟随或复制。

## 安全与限制

来源与实际备份目录不得相互嵌套。失败时保留原件并清理未完成的临时文件。用户可随时停止；已完成的文件写入清单，再次运行即继续。当前没有恢复、加密、照片图库或安卓 MTP 支持。设备来源无法像文件夹那样对源文件重读校验：完整性依靠 ImageCaptureCore 的下载结果、与设备报告大小一致的检查，以及写盘后计算并记录的 SHA-256。目的盘的可靠性、容量和加密由用户负责。应用为 ad-hoc 签名，未经 Apple 公证。
