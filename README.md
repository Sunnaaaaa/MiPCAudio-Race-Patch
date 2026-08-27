# 小米电脑管家 MiPCAudio 启动竞态补丁

本补丁用于处理小米电脑管家反复启动、强制结束 `MiPCAudio.exe`，进而造成鼠标光标持续转圈，以及 `C:\ProgramData\MI\Miplay\AudioShare\mpa` 持续生成日志的问题。

补丁不会关闭、卸载或整体禁用小米电脑管家，也不会禁用音频共享功能。它只将控制模块等待 `MiPCAudio` 建立本地通信管道的时间从 200 ms 调整为 350 ms。

补丁使用 Windows 自带的 PowerShell 运行，不需要安装开发工具或其他软件。请保留本文件夹内的 `.ps1` 和三个 `.cmd` 文件。

## 升级管家后如何操作

1. 先观察是否再次出现光标持续转圈、`MiPCAudio.exe` PID 不断变化或日志按秒生成。
2. 双击 `Status.cmd`。如果显示当前等待时间为 `200 ms`，且最近通信状态为 `循环失败（-4058）`，再继续。
3. 双击 `Patch.cmd`。
4. Windows 弹出管理员权限确认时选择“是”。
5. 程序会自动完成备份、补丁、重启和最长约 35 秒的验证。
6. 看到“IPC 连接成功，MiPCAudio PID 持续稳定”即表示成功。

补丁程序会从 `C:\Program Files\MI\XiaomiPCManager\.run` 自动读取当前版本，因此升级后不需要手工修改版本路径。

## 一键还原

双击 `Restore.cmd` 并确认管理员权限。程序会恢复当前版本的原始 DLL，然后重新启动小米电脑管家。

每个管家版本的备份独立保存在对应版本目录：

```text
MiPlayPCAudioDll.dll.mipaudio-patch-backup
```

## 安全机制

- 不使用固定文件偏移盲改。程序会解析 PE 导入表，找到 `Kernel32!Sleep`，再验证完整指令结构。
- 必须只找到一个安全补丁点，否则拒绝修改。官方升级改变代码结构时不会强行打补丁。
- 首次修改前自动备份原始 DLL，并校验备份中的等待值必须是 200 ms。
- 修改后自动检查管家是否运行、日志是否出现 `Connect successed`、`MiPCAudio` PID 是否稳定。
- 验证失败会自动恢复原 DLL，并重新启动电脑管家。

## 注意事项

- 修改 DLL 后，其小米数字签名会显示 `HashMismatch`。这是因为文件内容发生了本地修改，并不表示补丁程序又注入了其他代码；实际只修改一个 32 位等待时间常量。
- 管家升级通常会安装一份新的官方 DLL，并覆盖补丁。升级后仅在问题复发时重新运行，不建议无故补丁。
- 如果 `Status.cmd` 或 `Patch.cmd` 报告“安全补丁点数量不是 1”，说明官方版本结构已经变化。不要手工修改，请改用官方修复版或重新分析新版。
- 官方发布包含重试/就绪握手的修正版后，建议运行 `Restore.cmd` 或直接升级到官方修正版，不再使用本补丁。

## 命令行用法

```text
powershell.exe -ExecutionPolicy Bypass -File .\MiPCAudioRacePatch.ps1 -Mode Status
powershell.exe -ExecutionPolicy Bypass -File .\MiPCAudioRacePatch.ps1 -Mode Apply
powershell.exe -ExecutionPolicy Bypass -File .\MiPCAudioRacePatch.ps1 -Mode Apply -DelayMs 350
powershell.exe -ExecutionPolicy Bypass -File .\MiPCAudioRacePatch.ps1 -Mode Restore
```

等待时间允许范围为 250–2000 ms，默认值和已验证值均为 350 ms。
