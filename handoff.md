# 项目交接

最后更新：2026-11-07

## 当前状态

Phone Photo Backup 已从 Python/Tkinter 改写为 macOS 原生应用（Swift 6 + SwiftUI，macOS 14+），支持英文与简体中文界面。备份规则与清单格式不变；当前不直连手机、不使用云端。

## 已完成与验证

- `BackupCore` 引擎：递归复制普通文件、分块 + fsync、SHA-256 校验、保留权限/时间戳/创建日期/扩展属性、跳过未变文件、变化文件另存冲突副本、可取消、exFAT 回退。
- SwiftUI 界面：文件夹选择与拖放、记住上次文件夹、扫描预览、确认对话框、按字节的进度条、停止、结果统计、错误列表、在访达中显示；菜单与快捷键（⌘O、⇧⌘O、⌘R、⌘B、⌘.）；备份期间防止休眠。
- `swift test`：9 项测试通过（只用临时模拟字节）。
- `scripts/build-app.sh` 生成 ad-hoc 签名的 `build/Phone Photo Backup.app`（约 1.5 MB），`codesign --verify --strict` 通过。
- 用 `PPB_SNAPSHOT_DIR` 自检在临时模拟文件（41 个、43.6 MB）上跑通扫描 → 备份 → 完成，中英文界面截图检查正常；再次运行全部跳过，修改文件后生成冲突副本。
- 兼容性：旧 Python 版在 Swift 版生成的备份上运行，结果为 41 个未变化、0 错误。

## 限制与待办

- 尚未在真实手机导出目录或真实外置硬盘（尤其 exFAT）上做用户验收；exFAT 回退路径没有自动化测试。
- 未经 Apple 公证；分发给他人需 Developer ID 签名与公证，否则首次需右键“打开”。
- 不支持 USB 设备直连（可考虑 ImageCaptureCore）、照片图库、恢复、加密或云同步。

## 启动与测试

从项目根目录运行：`scripts/build-app.sh && open "build/Phone Photo Backup.app"`

运行测试：`swift test`
