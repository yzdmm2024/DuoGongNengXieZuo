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

## 指定注入的 App / 键盘
`KeyboardStatus.plist` 用 `Filter → Classes` 列出注入触发类：
`UIKeyboardDockView`（系统键盘底栏，含 iOS16）与 `UIInputSetHostView`（键盘容器，第三方键盘宿主 / iOS17 无 dock 的系统键盘都走这）。
任一类被加载时 dylib 才注入，覆盖系统键盘与第三方键盘（微信输入法等）；系统关键进程仍在 `%ctor` 里硬排除。
要限定范围，编辑 `Filter → Bundles` 数组即可。

## v1.5.2（紧急修复：1.5.0/1.5.1 整个插件不加载）

- **根因**：v1.5.0 把 `KeyboardStatus.plist` 的 `Filter` 清空成 `{}`，本意是"注入所有进程 + %ctor 黑名单"。
  但 ElleKit/theos 的规则是 **Filter 为空 = 没有注入条件 = dylib 永不加载进任何 App**。
  于是 1.5.0/1.5.1 整个插件是死的：工具栏不出现、"启用插件"开关怎么拨都没反应、改设置不生效——全部因为代码根本没跑。
  这正对应"1.2.9 有、越更新越没有"。
- 恢复成标准 `Filter → Classes` 注入（见上），与 1.2.9 同一套可靠机制。
- 顺带放宽第三方键盘判定：原来只在"容器里是远程键盘占位视图"时才挂，iOS17 无 dock 的**系统**键盘会被漏掉；
  现在改为"容器里装的是键盘（dock / 远程 / `UIKeyboard`·`UIKB` 系列）就挂，有 dock 仍交给 dock 处理"，iOS16/17 系统键盘与第三方键盘通吃。

## v1.5.1（第三方键盘：微信输入法等）

- **修「微信输入法下没有工具栏」**：frida dump 键盘窗口确认，第三方键盘挂在 `UIInputSetHostView` 上的是远程占位视图 `_UIRemoteKeyboardPlaceholderView`，**压根没有 `UIKeyboardDockView`** —— 只 hook dock，第三方键盘下工具栏必然不出现，所以关/开「启用插件」看着也没反应。
- 新增 `%hook UIInputSetHostView`：仅当容器内**没有 dock 且确实是远程键盘容器**时才挂载，系统键盘仍走原来的 dock 路径，两种键盘不会重复挂两份。
- 位置：第三方键盘占满屏幕底部，没有 dock 那条空位，工具栏改为挂在**键盘上方**（复用「抬高」滑块调上下）。
- 工具栏构建逻辑抽成 `ksBuildToolbarIn(container, atTop)`，两种容器共用一套。
- `ksInstallMethods` 改为**按类注入**（原来是全局只装一次）：现在有两个可能的挂载容器，只装一次会让第二个容器的按钮点击 `unrecognized selector` 直接崩。

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
