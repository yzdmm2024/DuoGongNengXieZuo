# 键盘下方状态（KeyboardStatus）

在 iOS 系统键盘**底栏**加一排**可用功能按钮**，外加一条（可选）只读状态条。

- 越狱环境：iOS 16 rootless（Dopamine / Relaxin / RootHide 隐根）
- 入口：系统「设置」→「键盘下方状态」

## 功能按钮（默认全开，可单独关）
全选 / 剪切 / 粘贴 / 光标左右移动 / 剪贴板历史 / 快捷短语（可增删、跨 App 共享）/ 收起键盘 / 一键清空。

- **一键清空**：按一下清空当前正在输入的输入框的全部内容；**长按清空键 = 撤销**，把刚清掉的内容放回去（防误触）。

## 状态条（可选，纯显示）
时间 / 电量 / 剪贴板预览 / 网络(WiFi/蜂窝)，约 1 秒刷新一次。

## 安全设计（防 dock 卡死 / 白苹果）
- **只注入普通 App**，明确排除 `SpringBoard` 与 `Preferences`（设置）。
- 全部逻辑包在 `@try/@catch`；任一动作异常都不影响宿主 App。
- 总开关 + 每个功能独立开关，出问题时关总开关即恢复原生键盘。
- 不调用 CoreTelephony 等易崩框架；网络检测用标准 BSD `getifaddrs`。

## 构建 / 发布
- 推送到 GitHub → Actions 自动出 `packages/*.deb`
- 走既有越狱源发布流程（同 超级截图 / 隐私总开关）

## 指定注入的 App
默认注入所有 App（filter plist 不做过滤），系统关键进程（SpringBoard / 设置 / WebKit / 崩溃上报等）在 `%ctor` 里硬排除。要限定范围，编辑 `KeyboardStatus.plist` 的 `Filter → Bundles` 数组即可。

## v1.5.0（性能回退 + 真修卡顿）
v1.4.0 为了排查 iOS17 问题堆了一堆运行期检测，实测是负优化，本次全部移除，只保留真有用的修复：
- **修「越来越卡」根因**：`layoutSubviews` 里读偏好近 20 次，旧实现每次都 `dictionaryWithContentsOfFile` 重读一遍 plist；键盘动画期间 layoutSubviews 每帧都跑 → 每秒上千次磁盘读 + plist 解析。现在整份偏好字典缓存 0.5 秒复用，收到面板通知立即作废（实时调节不受影响）。
- **移除 0.6 秒偏好文件轮询**：darwin 通知 + 键盘每次 layout 重读已足够，定时器纯属白跑主线程。
- **移除刷新时的窗口全树递归**：原来每次刷新都把所有窗口的整棵视图树走一遍（O(整棵树)），现在只对已登记的 dock 实例 `setNeedsLayout`。
- **移除 3 秒全量类扫描 / 运行时 swizzle**：回到 theos 原生 `%hook UIKeyboardDockView`，零开销。附带修掉 1.4.0 最严重的 bug——模糊匹配 `KeyboardDock` 把 `UIKeyboardDockItemButton`（dock 上的每个按钮，UIButton 子类）也 hook 了，导致往每个按钮内部塞一整套工具栏，视图数量爆炸并破坏 UIButton 内部布局（部分 App 因此闪退）。
- **修「改了设置键盘没反应」真因**：filter plist 用 `Classes: UIKeyboardDockView` 做过滤，在 ElleKit / RootHide 下时常不生效 → frida 实测插件根本没注入目标 App。改为不做过滤 + 代码内进程黑名单。
- **移除诊断系统**（诊断文件写盘 + 设置页诊断 cell）：它是排查用的，留在正式版里只会持续消耗主线程 IO。

## v1.3.0 修复记录
- **修「重装后改设置不生效」**：偏好文件路径旧实现用 `dispatch_once` 缓存，重装后首次启动 plist 还没建 → 缓存成 nil 且永不重试 → tweak 一辈子退回 CFPreferences 读值（读不到面板写的），所有开关看着都无效。现在命中才缓存，未命中 1 秒后重试。
- **修「关了启用开关工具栏还在」**：根因同上（`enabled` 读不到 = 默认开）。另外关开关时改为递归摘除所有已挂工具栏，不再只摘一层。
- **修「改设置要收起键盘才生效」**：改用 dock 实例登记表（弱引用）直接刷新，不再遍历窗口碰运气。
- **修「方法注入可能整体失效」**：`UIKeyboardDockView` 延迟加载时旧代码 `if(!cls) return` 会把通知监听一起跳过，现在监听无条件注册、方法注入改成懒注入。
- **新增一键清空按钮**（单击清空当前输入框，长按撤销）。
