# 验证记录

每次行为变化或发布前的验证结论按日期倒序记在这里，注明运行环境、通过的检查和仍待实机验证的项目。自动化无法覆盖的场景必须写进“未验证”，不要只留在对话或提交说明中。

## 2026-11-24 修复快捷键唤起面板时旧位置闪现

关闭 `HistoryWindow` 的 `hidesOnDeactivate` 与默认出现动画（`animationBehavior = .none`），在 `applicationResignedActive()` 中当面板可见且无模态弹窗时主动 `hide()`（`orderOut(nil)`，已隐藏时保留直接粘贴票据）；并在 `PanelFrameController` 离屏定位时关闭隐式 `CATransaction` 动画，通过 `setFrame(_:display: false)`、`layoutIfNeeded()`、`invalidateShadow()` 与 `CATransaction.flush()` 同步提交新坐标后再显示面板。同步补充失活 `orderOut` 与直接粘贴票据保护的回归断言。

在本机（Apple Silicon）通过：
- `bash macOS/check-strings.sh`（309 条英文文案与格式参数）与 `bash macOS/check-docs.sh`（64 个源文件模块地图）
- `swift build --scratch-path .work/swiftpm`（双模块编译）及原生测试目标 `-warnings-as-errors` 编译（含新增回归断言）
- `bash macOS/install.sh`（arm64 与 x86_64 双架构 Release 编译、沿用原签名身份并满足 Designated Requirement 校验、备份旧版并替换启动 `/Applications/ClipNest.app`）

未验证：未执行测试二进制（按用户要求跳过运行测试）；实机在不同屏幕位置与跨 Space 下反复用快捷键唤起面板、以及切换其他应用隐藏后再次唤起的无闪烁观感。

## 2026-11-24 代码精简与轻量化重构

清理死代码（`PanelUndoState`、`HistoryService.deleteEntry`、`PanelActions.delete`、`AppError.Code.io`、未用快捷键适配方法、7 处冗余 `#if SWIFT_PACKAGE` 条件导入及未用 `import Carbon`），移除休眠的来源图标视图与 `RowIconCache`（保留 `@应用名` 搜索和辅助功能来源朗读）及零读取的 `Entry.hasRichText` 启动计算列，收敛 `PanelActions` 纯透传层、空壳横幅子类与只读 `NSTextView` 工厂，并将 `HistoryPanelController` 6 个文件合并为 3 个、`RankingWeights.swift` 并入 `SearchRanker.swift`（生产代码 69 → 64 文件，7,313 → 7,105 行，净减 208 行；测试净减 47 行），同时将 `swift test` 纳入 `macOS/test.sh`。

在本机（Apple Silicon）通过：
- `bash macOS/check-strings.sh`（309 条英文文案与格式参数）与 `bash macOS/check-docs.sh`（64 个源文件模块地图与主类型命名一致性）
- `swift build --scratch-path .work/swiftpm`（双模块编译，无警告错误）与 `swift test --scratch-path .work/swiftpm`（20/20 项核心测试通过）
- 原生测试 `-warnings-as-errors` 编译通过，并运行通过前 31/32 项原生用例（含“原生历史行与背景绘制”“中英文单行底栏”“直接粘贴与权限引导”“读取冻结的第四版历史数据库”“图片文字面板交互”及“原生面板交互”首个子项，随后按用户要求停止测试进程）
- `bash macOS/install.sh`（arm64 与 x86_64 双架构 Release 编译、沿用原签名身份并满足 Designated Requirement 校验、备份旧版并替换启动 `/Applications/ClipNest.app`）

未验证：“原生面板交互”剩余子项（测试运行中按用户要求提前停止）；更新 `/Applications/ClipNest.app` 后的实机面板预览、暂停/授权横幅显隐、右键菜单与中英文切换抽检。

## 2026-11-24 默认开启直接粘贴与权限引导

将“直接粘贴到当前应用”改为默认开启，优化 `Paster` 的焦点让渡（macOS 14+ `yieldActivation`）、50ms 焦点稳定延迟及 `.cgSessionEventTap` 会话事件投递，并在未授予辅助功能权限时补充首次系统授权弹窗与面板内一键授权横幅。

在本机（Apple Silicon）通过：
- `bash macOS/check-strings.sh`（309 条英文文案与格式参数）与 `bash macOS/check-docs.sh`（69 个源文件模块地图）
- `swift test --scratch-path .work/swiftpm`（20/20 项核心测试通过）与 `swift build --scratch-path .work/swiftpm`
- `bash macOS/test.sh` 中 31/32 项原生用例通过（含新增的“直接粘贴与权限引导”、中英文 360/460 点宽度下辅助功能横幅布局、偏好默认值与“图片文字面板交互”）
- `bash macOS/install.sh`（arm64 与 x86_64 双架构 Release 编译、沿用原签名身份并满足 Designated Requirement 校验、备份旧版并替换启动 `/Applications/ClipNest.app`）

未验证：“原生面板交互”完整用例（运行期间本机前台窗口切换至 Chrome/POPO/Cursor 导致测试窗口失去焦点超时）；真实授予辅助功能权限后向 Electron/浏览器/终端及原生应用投递 `⌘V` 直接粘贴输出，以及首次无权限时系统辅助功能弹窗与“前往授权”按钮跳转的实机交互。

## 2026-11-24 发布 1.2.0（9）

将 `macOS/Info.plist` 版本更新为 `1.2.0`（Build `9`）并更新 `CHANGELOG.md` 后，在本机（Apple Silicon）执行完整验证：通过 `swift test --scratch-path .work/swiftpm`（20/20 项核心测试全部通过）、307 条中英文文案与格式参数检查、69 个源文件模块地图一致性检查、`swift build` 双模块编译、原生测试 30/31 项（覆盖 v2/v3 迁移、冻结的 v4 数据库、Vision OCR、剪贴板、历史与收藏、多语言与设置窗口等）以及 `bash macOS/install.sh`（arm64 与 x86_64 双架构通用包构建、沿用既有签名身份并通过严格校验、备份旧版并正常启动 `/Applications/ClipNest.app`）。

未验证：`原生面板交互` 用例因测试运行期间当前前台应用占用窗口焦点导致超时（前 5 个子项已通过，空格打开预览与点击复制环节在焦点丢失时超时）；Intel 与 macOS 13 真机运行、物理 Fn 组合键、真实中文输入法候选窗及物理多显示器切换。

## 2026-11-24 去掉右键菜单行蓝色外框

`HistoryTableView.menu(for:)` 改为直接返回 `menu` 而不调用 `super.menu(for:)`，消除弹出右键菜单时系统叠加在行外围的 `NSMenuHighlightView` 蓝色边框，同时保留 `HistoryRowView` 的悬停/选中背景填充。已通过 `macOS/check-strings.sh`、`macOS/check-docs.sh`、原生测试编译与 `CLIPNEST_TEST=原生历史行与背景绘制` 回归用例（1/1 通过，确认右键触发菜单且外沿像素透明、行中背景保留），以及 `bash macOS/install.sh`（双架构构建、签名校验并替换启动 `/Applications/ClipNest.app`）。

未验证：全量 `bash macOS/test.sh`、替换后实机右键菜单视觉效果。

## 2026-11-24 维护性重构

拆分 `HistoryPanelController`、`HistoryLayout`（原 `HistoryViews`）与原生测试文件，将面板定位、按键路由和快捷键校验的纯逻辑移入 `ClipNestCore` 并补充 SwiftPM 用例，新增冻结的第 4 版数据库样本、`check-docs.sh` 与原生测试的 `CLIPNEST_TEST` 过滤。已通过文案（307 条）与模块地图（69 个源文件）检查、单模块/双模块 `-warnings-as-errors` 编译检查，以及 `bash macOS/install.sh`（arm64 与 x86_64 双架构 Release 编译、沿用原签名身份校验、备份旧版并替换启动 `/Applications/ClipNest.app`）。

未验证：`swift test`、`bash macOS/test.sh` 的实际运行、替换后本机面板的交互实测，以及在非沙箱环境下运行 `swift build`。

## 2026-11-23 清理冗余代码

清理冗余代码、旧版图标与过期文档并润色文案后，在本机（Apple Silicon）通过 282 条中英文文案与格式参数检查、`bash macOS/build.sh`（arm64 与 x86_64 双架构编译、生成 `ClipNest.icns`、临时签名校验及通用 ZIP 打包）以及 `macOS/test.sh` 全量测试（29/29 项全部通过，覆盖图片文字提取文案与面板交互、Vision OCR 识别与调度、v2/v3 数据库升级、模糊与正则搜索及原生设置与面板窗口）。

未验证：Intel 与 macOS 13 真机运行、物理 Fn 组合键、真实中文输入法候选窗、多显示器切换、真实微信聊天截图识别效果以及持续后台识别的 CPU 占用。

## 2026-11-23 按指针位置打开面板

将面板固定为按指针位置打开，并在底栏加入设置齿轮。Apple Silicon 本机运行 `bash macOS/test.sh` 通过 29/29 项测试，274 条英文翻译和格式参数检查通过。原生 AppKit 窗口测试验证了中英文界面在 360 和 460 点宽度下的搜索框与四个底栏按钮布局、齿轮的悬停与辅助功能提示，以及点击齿轮返回已打开的设置窗口。定位测试覆盖副屏坐标、屏幕边缘、面板伸缩与拖动后的边界计算。`bash macOS/build.sh` 已完成 arm64 和 x86_64 双架构构建、临时签名校验及 ZIP 完整性检查。

同日用真实窗口验证了切换应用后的重新唤起。切回原应用时，macOS 已隐藏面板，但窗口的 `isVisible` 仍返回 `true`。再次唤起时面板按当前指针定位。同一次展示期间移动面板后重复唤起，窗口保持在移动后的位置。

未验证：使用物理鼠标按住标题留白拖动面板后继续搜索、物理双屏切换以及 VoiceOver 实际朗读。

## 长期未验证项

- 原生 `NSTextView` 组合输入测试使用 AppKit 的 marked text 接口，真实中文输入法候选窗口和整体界面响应耗时仍待实机验证。
