# 架构说明

## 当前实现

项目是 macOS 原生桌面应用（Swift 6 + SwiftUI，最低 macOS 14）。来源有两种：通过 USB 直连的手机（iPhone/iPad，或 PTP 模式的安卓手机，经 ImageCaptureCore 读取），或已导出到电脑的文件夹；目标是另一个本地备份位置。程序不调用云服务，不转换媒体内容（对支持 HEIF 的设备请求原始 HEIC/HEVC 而非转码后的 JPEG/H.264），不修改或删除手机上的文件。

## 模块职责与数据流

| 模块 | 职责 | 边界 |
| --- | --- | --- |
| `Sources/BackupCore/BackupEngine.swift` | 路径校验、递归扫描、复制、SHA-256 校验、冲突版本处理、进度与取消 | 只写用户选定的目标目录；不修改或删除来源文件；不依赖界面 |
| `Sources/BackupCore/StagedBackup.swift` | 设备来源的备份：设备计划、设备路径清理、逐个取回文件到本机临时目录的暂存区、核对大小、SHA-256；与备份同卷时 fsync 后重命名，跨卷时以 8 MB 大块复制并边写边校验；已备份且大小一致的文件不再从设备读取 | 通过注入的 `Fetch` 闭包取文件，不依赖 ImageCaptureCore；暂存区 `$TMPDIR/PhonePhotoBackup-staging-<UUID>` 用完即删，启动时清理旧残留和旧版放在备份目录里的 `.phone-photo-backup-staging` |
| `Sources/BackupCore/PhotosImport.swift` | 导入「照片」的计划：读取各备份清单，按 SHA-256 跨备份去重，排除导入记录中已有的文件，配对实况照片（同目录同名的照片 + `.mov`）；导入记录 `.phone-photo-backup-photos.json`；按文件名主干 + 拍摄时间（容许 ±14 小时整点时区偏差、2 秒误差）识别图库中已有的照片 | 纯文件逻辑，不依赖 PhotoKit |
| `Sources/BackupCore/PhoneReview.swift` | 备份前检查：最大的视频、完全相同的重复项（先按大小筛选候选，再由注入的哈希函数确认）、删除前核对备份（清单中同大小版本且副本存在）、取得备份副本的 SHA-256 | 纯逻辑，不删除任何东西 |
| `Sources/BackupCore/BackupVideos.swift` | 列出备份位置下的视频（跳过隐藏文件，不跟随符号链接，标出实况照片的视频）、生成带视频总大小的文件夹树、按文件夹筛选 | 纯文件逻辑，只读 |
| `Sources/BackupCore/DirectImport.swift` | `TimeIndexedLibrary`：按拍摄时间索引图库，只对时间吻合的项目读取文件名（规则同 `LibraryIndex`）；手机项目配对为照片/视频/实况照片；导入记录里的手机文件记录（设备 + 路径 + 大小） | 纯逻辑；文件名读取由注入的闭包完成 |
| `Sources/BackupCore/ExistingBackups.swift` | 跨备份去重索引：备份盘上所有带清单的 `*_backup` 文件夹，加上用户选的「参照文件夹」（本 App 的备份用清单；普通文件夹逐个列出）。预览按「文件名 + 大小」估算已备份数量，备份时按 SHA-256 精确匹配（普通文件夹只对大小相同的文件计算哈希）| 只读；重复文件不再存储，清单里 `backup_path` 记为 `../其他备份/…` |
| `Sources/BackupCore/Manifest.swift` | 读写 `.phone-photo-backup.json`（schema 1，与旧 Python 版兼容） | 原子写入；无法读取或不匹配时在复制前中止 |
| `Sources/BackupCore/FileSystem.swift` | POSIX 辅助：`lstat`、排他创建、排他发布、元数据复制 | 不跟随符号链接 |
| `Sources/PhonePhotoBackup/DeviceBrowser.swift` | ImageCaptureCore：发现 USB 设备、打开会话、读取完整文件列表（含 Live Photo 视频等附属文件）、下载单个文件、按范围读取文件片段（预览、查重）、请求指定尺寸的缩略图；文件数连续 8 秒不变才算列表读完（大图库要约 30 秒）；按路径找不到时按「文件名 + 大小」重新定位；手机锁定或断开时等待恢复并重读列表 | 只读设备；不删除、不上传 |
| `Sources/PhonePhotoBackup/PhotoLibraryImporter.swift` | PhotoKit：申请读写权限、读取图库已有项目的文件名与创建时间、读取备份文件的拍摄时间（EXIF/视频元数据，缺失时用文件时间）、创建照片/视频/实况照片并加入“从旧手机导入”相簿；实况照片配对失败时分开导入 | 只添加，不修改或删除图库中已有项目；`shouldMoveFile = false`，备份文件保持不动 |
| `Sources/PhonePhotoBackup/ReviewView.swift` | 检查清单窗口：`ReviewSession` 计算大视频和重复项（从手机分块读取计算 SHA-256）、缩略图、勾选；默认勾选重复组中除最早一份外的副本 | 只做选择；删除由模型在备份后经「照片」执行 |
| `Sources/PhonePhotoBackup/MediaPreview.swift` | 检查清单里的大图/视频预览：有备份副本时播放副本；否则 `PhoneStreamLoader`（`AVAssetResourceLoaderDelegate`）按播放器请求的字节范围从手机分块读取，不先复制整个文件；照片整份读入内存显示；“保留/删除”按钮修改勾选并跳到下一项 | 只读手机和备份；不写临时文件 |
| `Sources/PhonePhotoBackup/BackupVideosView.swift` | “备份里的视频”窗口：左侧文件夹树，右侧按大小/日期/名称排序的视频列表（Quick Look 缩略图、时长），预览复用 `MediaPreviewSheet`，标记后移到废纸篓 | 只移到废纸篓，不直接删除；备份或导入进行中不能移动；不修改清单 |
| `Sources/PhonePhotoBackup/BackupModel.swift` | `@MainActor @Observable` 状态：来源（文件夹或设备）选择与记忆、参照文件夹、新接入的手机自动设为来源、自动模式（接入即扫描 → 备份 → 导入，每台手机每次启动只自动运行一次）、扫描/备份/导入任务、进度、取消、防休眠 | 在后台任务中调用引擎 |
| `Sources/PhonePhotoBackup/ContentView.swift` | SwiftUI 界面：来源行（菜单列出已连接手机或选择文件夹，支持拖放）、手机状态、状态面板、确认对话框、结果与错误列表 | 不含文件操作逻辑 |
| `Sources/PhonePhotoBackup/PhonePhotoBackupApp.swift` | 应用入口、单窗口、菜单与快捷键 | — |
| `Sources/BackupCore/AppUpdate.swift` | 版本号比较、解析 GitHub `releases/latest`、选出 `Phone-Photo-Backup-<版本>.zip` 及其 SHA-256（GitHub 的 `digest`，或发布说明里的 `SHA-256:` 行）；校验并解压下载（SHA-256、包标识、版本、`codesign --verify --strict --deep`）；生成替换脚本（等旧进程退出 → 旧包移开 → 新包移入，失败放回 → 重新打开 → 清理） | 不联网；只在临时目录和应用所在位置操作 |
| `Sources/PhonePhotoBackup/Updater.swift` | 检查更新（启动时每天最多一次，可关闭；菜单“检查更新…”）、更新窗口、下载进度、调用核心校验、启动替换脚本后退出 | 只在用户点“安装并重启”且没有备份或导入进行时安装；自检模式和无 bundle 运行时不检查 |
| `Sources/PhonePhotoBackup/AppLanguage.swift` | 应用菜单「语言」：跟随系统 / English / 简体中文，写入本应用的 `AppleLanguages`，提示重新打开 | 只改本应用设置；有备份或导入进行时不重新打开 |
| `Sources/PhonePhotoBackup/SelfCheck.swift` | 开发自检：设置 `PPB_SNAPSHOT_DIR` 时自动运行流程并保存窗口截图 | 默认不启用 |
| `Resources/`、`scripts/` | Info.plist、en/zh-Hans 本地化；打包 `.app`、生成图标 | — |
| `Tests/BackupCoreTests/` | 用临时模拟字节测试复制、跳过、冲突、清单、重叠路径、符号链接、元数据、取消；用模拟设备测试设备来源的复制、免重读、冲突、下载不完整/失败、取消与继续、路径清理 | 不访问私人照片或真实设备 |

流程：界面读取两个目录 → 引擎解析真实路径并验证源和目标不重叠（不区分大小写）→ 扫描普通文件并预览数量/体积 → 用户确认 → 对每个文件计算 SHA-256 → 分块写入 `.part` 临时文件并 `fsync` → 确认源文件大小/修改时间未变且哈希一致 → 复制权限、时间戳（纳秒）、创建日期、扩展属性 → 排他地发布到目标（`renamex_np(RENAME_EXCL)`，否则硬链接，再否则检查后重命名，以支持 exFAT）→ 最后原子更新清单。目标以来源目录名加 `_backup` 命名，保持相对目录结构。

设备来源流程：发现设备 → 打开会话（iPhone 会提示“信任此电脑”）→ 等待完整文件列表 → 按设备上的文件夹结构生成相对路径和计划（备份目录为 `<设备名>_backup`）→ 用户确认 → 对每个文件：若清单中已有相同大小的版本且备份副本仍在则跳过，否则下载到本机临时目录的暂存区 → 核对大小与设备报告一致 → SHA-256 → 与文件夹来源相同的跳过/冲突规则；本备份里已有同 SHA-256 的副本则指向它；其他备份或参照文件夹里有同 SHA-256 的副本则记为「重复」，不再存储 → 排他发布（同卷：fsync 后重命名；跨卷：8 MB 大块复制、边写边校验 SHA-256、fsync、复制时间戳后排他发布）→ 最后原子更新清单。手机锁定或断开时下载在原地等待，恢复后重新读取文件列表并继续；用户可随时停止。

设备备份文件夹归属：文件夹内的 `.phone-photo-backup-device` 记录设备编号。同名手机或同名的文件夹备份已占用 `<名称>_backup` 时，依次改用 `<名称> 2_backup`、`<名称> 3_backup`。

删除流程有两种顺序。先删除再备份：用户勾选 → 按下面相同的匹配规则在「照片」中移到“最近删除” → 已删除的项目从备份计划中去掉 → 备份其余内容；删除出错（无权限、拒绝系统确认）时停在清单，不备份。先备份再删除：手机来源点“开始备份”时先打开检查清单 → 用户勾选 → 备份（选择不备份所选项目时把它们从计划中去掉）→ 需要备份时只保留经核对的项目 → 对每个所选项目按拍摄时间 ±2 秒查询图库，再比对文件名主干（唯一匹配，不容许时区偏差；不读取整个图库）找到对应项目 → `PHAssetChangeRequest.deleteAssets` 移到“最近删除”（macOS 会请求确认）→ 把已删项目的 SHA-256 以 `deleted` 写入导入记录，防止导入步骤把它们放回。应用从不直接删除手机上的文件。

直接导入流程（不备份）：开启“备份或导入手机前检查”时，先读取手机文件列表并打开检查清单（`ReviewSession.purpose == .directImport`）；“删除所选项目，再导入”先经 PhotoKit 删除已在「照片」里的所选项目，然后把全部所选项目（实况照片任一半被选即整项）作为排除项交给导入，导入记录把它们记为 `deleted` / `skipped`，以后不再导入；“只导入，不删除”直接导入且不再弹确认框。之后：取得权限 → 读取导入记录（有备份位置时用备份位置里的，否则用 `~/Library/Application Support/Phone Photo Backup/`）→ 读取手机文件列表并配对 → 去掉导入记录里已处理的手机文件 → 确认数量 → 按拍摄时间索引图库 → 对每项：图库已有同名同时刻的直接记为“已在照片中”（不读手机）；否则下载到临时目录，按文件内的拍摄时间再查一次图库、按 SHA-256 查导入记录和本次已见内容，都没有才导入；删除临时文件 → 记录手机文件。

导入「照片」流程：取得权限 → 读取导入记录 → 规划（跨备份去重、排除已导入、配对实况照片）→ 手动导入时先确认数量 → 读取图库索引 → 对每项：读取拍摄时间，图库里已有同名同时刻的项目则记为“已在照片中”，否则创建资源并加入相簿 → 每 25 项保存一次导入记录 → 结束时保存。用户可随时停止，再次运行会跳过已记录的文件。

相同相对路径且哈希未变时跳过；若内容变化，则保留原文件并将新版本写为 `<名称>.conflict-<哈希前8位>.<扩展名>`。清单按相对路径追踪不同版本，不保存原始绝对路径。符号链接不会跟随或复制。

## 安全与限制

来源与实际备份目录不得相互嵌套。失败时保留原件并清理未完成的临时文件。用户可随时停止；已完成的文件写入清单，再次运行即继续。当前没有恢复、加密或安卓 MTP 支持；「照片」只做导入，不读取图库内容做备份。设备来源无法像文件夹那样对源文件重读校验：完整性依靠 ImageCaptureCore 的下载结果、与设备报告大小一致的检查，以及写盘后计算并记录的 SHA-256。目的盘的可靠性、容量和加密由用户负责。应用为 ad-hoc 签名，未经 Apple 公证。唯一的网络请求是检查更新（`api.github.com`）和下载更新包；更新的可信度依靠 HTTPS 和 GitHub 发布页给出的 SHA-256，ad-hoc 签名只能证明包未被改动，不能证明来源。
