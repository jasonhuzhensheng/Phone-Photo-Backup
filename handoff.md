# 项目交接

最后更新：2026-09-26

## 当前状态

Phone Photo Backup 首版桌面应用已实现并发布到公开仓库 `jasonhuzhensheng/Phone-Photo-Backup`。用户选择将手机导出后的照片文件夹复制到本地备份位置；当前不直连手机、不使用云端。

## 已完成与验证

- Tkinter 桌面界面：选择源目录和目标位置、扫描文件数/字节数、显示备份进度与结果。
- 备份引擎：递归复制普通文件、分块处理、SHA-256 校验、保留文件时间、跳过未变文件；内容变化时保留旧文件并另存冲突版本。
- 来源清单使用相对路径，不保存原始绝对路径；不跟随符号链接，不修改或删除来源文件。
- 5 项单元测试通过，测试只使用临时模拟字节；`py_compile` 与 `git diff --check` 通过。Python 3.11/Tkinter 在当前 Mac 可用。
- 仓库公开地址：https://github.com/jasonhuzhensheng/Phone-Photo-Backup 。忽略规则排除照片、视频、备份、密钥、数据库和本地缓存。

## 限制与待办

- 尚未在真实手机导出目录或外置硬盘上做用户验收。
- 不支持 USB 设备直连、iCloud/Photos API、恢复、加密、断点续传或云同步。
- 后续可根据用户需要增加设备导入或恢复功能；任何验证仍只用临时/模拟文件，禁止把私人照片提交到 GitHub。

## 启动与测试

从项目根目录运行：`python3 src/desktop_app.py`

运行测试：`python3 -m unittest discover -s tests -v`
