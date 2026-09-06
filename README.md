# 键盘下方状态（KeyboardStatus）

在 iOS 系统键盘**底部**显示一行**只读**状态信息：时间 / 电量 / 剪贴板预览 / 网络。

- 越狱环境：iOS 16 rootless（Dopamine / Relaxin / RootHide 隐根）
- 入口：系统「设置」→「键盘下方状态」
- 设计原则：纯展示、**不注入主屏幕(SpringBoard)与设置(Preferences)**、不挂 dock、不调危险 API，零白苹果风险。

## 设置项
总开关 + 时间 / 电量 / 剪贴板 / 网络 四项独立开关，改动即时生效（约 1 秒内）。

## 构建 / 发布
- 推送到 GitHub → Actions 自动出 `packages/*.deb`
- 走既有越狱源发布流程（同 超级截图 / 隐私总开关）

## 指定注入的 App
编辑 `layout/Library/MobileSubstrate/DynamicLibraries/KeyboardStatus.plist` 的 Bundles 数组，加入目标 App 的 bundle id 即可。
