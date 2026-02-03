# BarPin MVP

这是一个最小可运行版本的菜单栏工具：点击菜单栏按钮后会启动或激活目标 App，并把它的主窗口移动到菜单栏按钮下方；用户拖动或缩放后会自动记住位置和大小，再次点击则隐藏该 App。

## 行为概览

- 默认控制系统自带的「日历」App（Calendar）。
- 点击菜单栏按钮：显示/定位目标 App 窗口。
- 再次点击：隐藏目标 App。
- 右键菜单可更换 App 或重置窗口位置。

## 运行说明

这是一个 SwiftPM 可执行程序（MVP）。建议在 Xcode 中直接打开目录运行，或使用命令行：

```bash
swift run
```

首次运行会提示授权辅助功能（Accessibility），请在系统设置里允许。

## 目录结构

- `Package.swift` SwiftPM 配置
- `Sources/BarPin/main.swift` 主要逻辑
