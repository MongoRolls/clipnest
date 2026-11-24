# AGENTS.md

本文写给 ClipNest 的长期维护者和编码代理。用户功能说明见 [README.md](README.md)，这里记录改代码前需要了解的约定、不变量和常见陷阱。

## 项目速览

- macOS 13+ 菜单栏剪贴板历史应用，Swift 5 + AppKit，**没有 Xcode 工程，也没有第三方依赖**。系统框架包括 AppKit、Carbon（全局快捷键/键位）、SQLite3、CryptoKit、Security、ServiceManagement、ImageIO、UniformTypeIdentifiers 和 Vision。
- `macOS/Sources/Core/` 是 SwiftPM 的 `ClipNestCore` 模块，`macOS/Sources/` 顶层是应用入口、服务和 AppKit 界面。原生脚本一起编译这两层的 Swift 文件。
- 代码注释、错误信息、本地化 key 使用简体中文；注释说明“为什么”，不复述代码。

## 长期维护原则

编码代理应以长期维护者的身份工作：判断一项改动时，先考虑一年后接手的人能否读懂、能否安全修改，再考虑这次能多做多少功能。

- **不变量先于代码**：涉及数据格式、线程模型、隐私约定的改动，先确认并更新本文对应段落，再改代码。发现代码与本文不符时，先查明哪一方正确，并在同一次改动中修正另一方。
- **已发布的格式只增不改**：数据库列、认证数据、钥匙串项、偏好键一经发布就视为对外接口。废弃字段保留兼容读取，并在本文注明保留原因。
- **文档跟随代码**：新增、重命名或删除源文件时同步更新模块地图，文件名与其中的主要类型保持一致（`check-docs.sh` 会检查）。README 只写用户可见行为，验证结论写入 `docs/VERIFICATION.md`，版本变化写入 `CHANGELOG.md`，本文只写维护约定，同一事实不在两处重复描述。
- **复杂度需要理由**：不引入第三方依赖和新的构建工具。新增抽象前确认已有两个以上调用方，或测试确实需要替换实现。能放进 `ClipNestCore` 的纯逻辑优先放进去，让无窗口测试覆盖。
- **先拆分再扩展**：单个文件超过约 500 行，或一个类型同时承担多项职责时，先做不改变行为的拆分，再在拆分后的位置加功能。
- **改动小而可回退**：一次提交只表达一个意图，重构与行为变化分开提交，方便 `git bisect` 和回滚。
- **每个修复都留下证据**：缺陷修复附带能复现原问题的测试；无法自动化的场景写入 `docs/VERIFICATION.md` 的未验证项，不要只在对话里说明。

## 构建与验证

```sh
swift test --scratch-path .work/swiftpm  # 无需窗口的核心测试
bash macOS/test.sh    # 文案与模块地图检查、SwiftPM 双模块编译与核心测试，再编译并运行原生测试（用 Tests/ 替换 main.swift）
bash macOS/build.sh   # 双架构编译、strip、生成图标、签名，产物在 artifacts/macos/
bash macOS/install.sh # 构建、备份并替换本机应用，随后重新启动
```

- 日常修改应用代码或随应用分发的资源后，默认运行 `bash macOS/install.sh` 更新本机 ClipNest，无需再次询问。脚本已包含构建步骤。仅改文档或测试时可跳过安装。用户当次指定暂停、只改代码或跳过构建、安装时，以当次要求为准。测试与安装分开执行。

- 完整应用需要 macOS 26 或更新的 SDK，以编译玻璃材质的系统接口，发布部署目标为 macOS 13。原生脚本共用 `macOS/compiler-flags.sh`，保留 `-warnings-as-errors` 和 `-package-name ClipNest`。测试使用 `-Onone -g`，发布使用 `-Osize -whole-module-optimization`。
- 测试需要访问真实 NSPasteboard 服务和窗口服务器：在无 GUI 会话或受限沙箱中运行时，剪贴板相关用例会报“写入系统剪贴板失败”。“原生面板交互”用例还需要测试窗口获得键盘焦点，其他应用抢占前台时会超时。这两类失败属于环境问题，不要为此修改产品代码。
- 原生脚本把 Core 与应用编成一个模块，SwiftPM 分成两个模块，应用层通过 `AppResources.swift` 的 `@_exported import ClipNestCore` 使用 Core。Core 中供应用使用的符号必须标为 `package`，否则只有 SwiftPM 构建会失败；`test.sh` 因此同时运行 `swift build`。
- 测试进程在失败时以 trap 结束，stdout 缓冲可能丢失；排查时看最后的汇总错误信息。
- 设置 `CLIPNEST_TEST=名称片段1,名称片段2` 只运行名称包含任一片段的原生用例，未匹配到任何用例时报错并列出全部名称。每个用例输出耗时。
- 每次测试在 `.work/macos/tests-<UUID>/` 下新建目录且不自动清理，可随时删除 `.work/`。`artifacts/` 同样被 git 忽略。
- 改动 UI 交互时，自动测试之外仍需实机确认（真实 Fn 按键、输入法候选窗、多显示器等目前无法自动化，见 `docs/VERIFICATION.md`）。

## 模块地图

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 入口 | `main.swift`、`AppDelegate.swift`、`AppResources.swift` | 单实例锁、菜单栏、设置变化分发、语言切换重建、`ClipNestCore` 资源与重导出 |
| 偏好 | `AppSettings.swift`、`Core/KeyboardSettings.swift`、`Core/HistoryShortcut.swift`、`Core/L10n.swift` | UserDefaults 读写与校验、快捷键模型、数字修饰键、运行时语言切换 |
| 服务 | `HistoryService.swift`、`StoreWorker.swift`、`CaptureMonitor.swift`、`Core/CapturePolicy.swift` | 写入准入、快照与观察者、串行数据库任务、轮询与收录策略 |
| 图片识别 | `Core/OCRScheduler.swift`、`OCRCoordinator.swift`、`ImageOCR.swift`、`CancellationToken.swift` | 调度事件和决策、后台识别与手动请求合并、Vision 识别和取消 |
| 存储 | `Core/Models.swift`、`Core/HistoryStore.swift`、`Core/HistoryDatabase.swift`、`Core/SchemaMigrator.swift`、`Core/RecordMapper.swift`、`Core/RecordCipher.swift`、`Core/KeyProvider.swift`、`Core/DatabaseRecovery.swift` | 领域模型、顺位与事务迁移、记录映射、逐列 AES-GCM、钥匙串访问、归档与恢复 |
| 剪贴板 | `ClipboardAccess.swift`、`Core/ClipImage.swift`、`Paster.swift` | 读写剪贴板、隐私标记与收录策略、图片处理、直接粘贴 |
| 面板 | `HistoryPanelController.swift`、`HistoryPanelController+Table.swift`、`HistoryPanelController+Actions.swift`、`PanelContent.swift`、`PanelCommands.swift`、`PanelKeyRouter.swift`、`Core/PanelKeyRouting.swift`、`Core/PanelShortcut.swift`、`Core/PanelPlacement.swift`、`PanelFrameController.swift`、`PanelActions.swift`、`RequestGuard.swift` | 面板控制器（生命周期与状态）、表格与右键菜单扩展、按键与记录操作扩展、列表与命令模型、按键路由、窗口定位、直接粘贴返回与清空确认、过期校验 |
| 视图与预览 | `HistoryPanelView.swift`、`HistoryLayout.swift`、`HistoryWindow.swift`、`HistoryTableView.swift`、`FooterButton.swift`、`HistoryCell.swift`、`ContentPreviewController.swift`、`HistoryPreviewCoordinator.swift`、`PanelBackground.swift`、`Core/ClipboardColor.swift`、`Core/EntryPresentation.swift` | 面板布局与共享扩展、窗口与列表、底栏按钮、行单元格与色块、内容预览、背景图 |
| 搜索 | `Core/HistorySearch.swift`、`Core/QueryParser.swift`、`Core/RegexSearcher.swift`、`Core/SearchRanker.swift`、`Core/FuzzyMatcher.swift`、`Core/AppMetadataCache.swift` | 查询解析、正则执行、全文与模糊评分及权重、来源应用名称 |
| 设置窗口 | `SettingsWindowController.swift`、`SettingsSidebarController.swift`、`SettingsPage.swift`、`SettingsPanes.swift`、`SettingsExcludedAppsView.swift`、`PanelBackgroundControls.swift`、`ShortcutRecorder.swift` | 侧栏设置窗口、侧栏搜索导航、分组卡片视图、各页控件、已排除应用卡片、背景与快捷键录制 |
| 系统 | `HotKey.swift`、`KeyboardLayout.swift`、`SystemAccess.swift`、`ErrorLog.swift` | Carbon 热键、键盘布局换算、权限/登录项、错误日志 |

应用目录、数据库、锁文件与日志路径在 `Core/AppPaths.swift`。轮询节奏、退出时限、图片解码尺寸和正则时间预算使用同文件的 `Tuning`。搜索评分见 `Core/SearchRanker.swift`。

## 线程模型（最容易出错的地方）

- 应用中，`@MainActor HistoryService` 只读 `StoreWorker` 发布的 `entries`、`favorites` 和 `favoriteIDs` 值快照。所有数据库任务从异步接口进入 `StoreWorker` 的同一串行队列。传给 `perform` 的闭包只在该队列内使用 store，禁止将 store 捕获到其他任务中。
- 复制、收藏和删除走 `HistoryService.perform(label, action:completion:)`。返回 `false` 表示未接收，返回 `true` 表示已经入队。已接收的动作无论成功或失败都发布最新快照。服务使用构造时注入的 `ErrorReporter` 上报故障。`observeChanges(owner:_:)` 支持多个观察者，回调应弱引用 owner；切换语言时移除旧面板订阅。
- 图片识别在独立队列运行。worker 读取原图、持久化识别结果并发布历史和收藏快照。后台逐张处理历史、再处理仅有收藏的图片，期间面板可以继续操作。后台索引和手动识别共用已保存的结果。同一图片识别出错时，手动操作可以重试。
- `isIdle == ready && !busy && !quitting` 是界面可操作的统一前提；新增按钮或菜单的可用状态也应基于它。
- 工作区的前台应用与通知通过 `FrontmostAppProvider`、`WorkspaceEvents` 注入。退出时先停止轮询和 OCR，等待已入队的任务及最后一次收录清理。默认 5 秒超时后写入诊断并回复退出，迟到的清理不得再次回复。
- 面板、文字提取和预览各自使用 `RequestGuard`。显示、隐藏、改变选择或查询时，使相应票据失效。异步动作需核对票据、当前条目和窗口状态，防止向旧窗口复制或粘贴。
- 顶部搜索框占满可用宽度。底栏左侧依次为列表切换按钮和设置齿轮，右侧为清空和退出，四个按钮共用一行。齿轮显示 `gearshape`，悬停提示包含 `⌘,`，辅助功能名称为“打开设置”。更新按钮文案时同步刷新宽度、悬停文字和辅助功能说明，保留 360pt 宽时的中英文覆盖。
- 每次打开面板时按指针所在屏幕选择显示方向，加载和搜索使用该次打开时的指针和方向。手动移动窗口后，后续调整沿用拖动后的位置，直到下一次打开。
- 搜索在 `HistorySearch` 的后台队列上进行；搜索未完成时按键动作会进入 `pendingKeys`，结果到达后再执行。切换列表、改词、重新唤起面板会清空队列。
- `EntryPresentation` 负责预览、检索字段和图片 OCR 命中摘要。`Entry.withOCR(_:)` 复用日期、缩略图和展示数据，只重算随 OCR 变化的搜索字段与词。搜索结果携带预览字符串中的 UTF-16 高亮范围，行视图直接使用该范围；搜索命中图片 OCR 文字时，行视图额外展示居中截断并高亮的 OCR 摘要片段。修改匹配规则时同时检查长正文、文件路径与组合字符。
- `ClipboardAccess` 的策略字段与观察到的来源统一经过 `stateLock`。以剪贴板版本关联首次观察到的前台应用。重复收录已收藏的内容时，同步发布历史和收藏的来源变化。

## 数据格式不变量（改动前必须设计迁移）

- `SchemaVersion.current` 定义 `history.db` 的版本，当前为 4。`SchemaMigrator` 在同一事务内按顺序从 v2 或 v3 升级再写版本号。v2 的 `records` 及已有的 `damaged_records` 依次追加 `source_app`、`tags`、`ocr_text`，v3 只追加 `ocr_text`。两张表的物理列顺序必须相同。v1 和其他无法识别的版本沿用 `history.v1.db` 备份路径。嵌套事务使用 SQLite SAVEPOINT，外层回滚必须撤销已完成的内层写入。
- `source_app` 按列加密保存 UTF-8 应用标识。无来源时为 SQL NULL，重复收录更新已知来源。为兼容已发布的第 3 版结构，保留 `tags` 列和旧密文。列表查询和新记录写入均省略该列。
- 非图片记录的 `ocr_text` 必须为 SQL NULL。图片的 SQL NULL 表示尚未识别，加密空串表示识别完成且无字，加密非空 UTF-8 表示可搜索的文字。该列按 `RecordHeader.authentication("ocr_text")` 加密，最多保存 1 MiB UTF-8，且与原图合计不超过 `Limits.bytes`。OCR 不参与内容指纹。重复收录同一图片保留结果。
- 新库将元数据排在大列之前，旧库原位升级遵循 SQLite 的追加列规则。业务读写显式列出列名，归档整行复制使用同一个数据库内结构一致的两张表。
- 记录 `id` 是 `RecordCipher.fingerprint(payload)` 的 SHA-256 十六进制串，同时用于去重和复制前的完整性校验。改变指纹算法会让所有已有记录校验失败。
- 每列密文的认证数据是 `"\(id):\(column):\(kind):\(width):\(height)"`（见 `RecordHeader.authentication`），列名就是 SQL 列名。重命名列或改变 kind 编号（0 文本、1 图片、2 文件）都会使旧数据无法解密。
- 密钥保存在钥匙串 `com.clipnest.history` / `history-key`。
- 启动通过 `lightColumns` 读取列表和 OCR 文字。复制、预览和识别按需读取各自的负载。OCR 全文支持关键词和正则匹配，仅前 4096 个字符参与模糊分词。图片行不输出文字高亮范围。
- 部分记录校验失败时整行移入 `damaged_records`；全部失败时保留原表并报错，防止错误密钥清空数据。
- 初次开库失败时，保留实际错误和开库方法以便重试。归档重建仅限已判定为损坏的数据库，需由用户明确确认。归档范围包含主文件及已有 WAL、SHM、journal。新库成功加载后才完成恢复流程。外部文件锁、只读目录或钥匙串访问失败时保留原文件并提示重试。
- `retainCaptureTail` / `withRetainedRecord` 保证界面仍显示、但已被后台淘汰的最后一条记录在复制完成前不被删除。修改淘汰或清理逻辑时保留这一机制。
- 偏好键在 `AppSettings.Key` 中定义，`keyboardSettings` 的原始值已发布。`ignoredBundleIDs` 未显式写入偏好时默认排除 `com.apple.keychainaccess`（钥匙串访问）与 `com.apple.Passwords`（密码）；用户修改或清空后会持久化真实列表，不再自动恢复。旧版位置键 `popupPosition` 留在用户偏好中，应用不再读写该键。
- `panel-background.plist` 保存背景图名称和重新编码后的 PNG（最长边 2048 像素）。

### 数据格式变更检查清单

改动 `history.db` 结构、加密方式或已发布的偏好前，逐项确认：

1. 先冻结当前版本：在原生测试中加入当前表结构、认证格式与指纹的字面量样本，之后不随源码修改。
2. `SchemaVersion.current` 加一，`SchemaMigrator` 补上从每个仍支持的旧版本出发的升级步骤，全部在同一事务内完成。
3. `records` 与 `damaged_records` 同步追加列，物理列顺序保持一致；新列只能追加，不重命名、不删除。
4. 认证数据格式、kind 编号与指纹算法保持不变；确需改变时设计双读期并在本文说明。
5. 测试覆盖每条旧库升级路径、升级失败回滚，以及旧版应用遇到新库时的行为。
6. 同步更新本节、README 的数据说明和 `CHANGELOG.md` 的“数据格式”条目，注明能否回退到旧版本。

## 界面材质

- macOS 26 及以上使用 `NSGlassEffectView.Style.regular`，macOS 13–15 使用 `.popover` 与 `.behindWindow` 磨砂材质。参考 [Maccy 的材质实现](https://github.com/p0deje/Maccy/blob/c700182f638d9d29bfa0aec9dc560422698854c6/Maccy/Views/VisualEffectView.swift) 和 [背景与内容分层](https://github.com/p0deje/Maccy/blob/c700182f638d9d29bfa0aec9dc560422698854c6/Maccy/Views/ContentView.swift)。
- 玻璃与内容使用独立视图层级，内容容器关闭 vibrancy，文字和图片保持完整不透明度；背景明暗、模糊与透光由系统材质处理，不叠加黑色遮罩。玻璃容器使用连续圆角裁切，旧系统材质使用 `maskImage` 裁切。

## 隐私约定

- `errors.log` 只记录时间、操作名、错误 domain 和 code，**绝不写入剪贴板正文、路径或错误描述**。
- 收录会跳过 `ClipboardAccess.ignoredTypes` 中的隐私标记以及本实例写入的 `com.clipnest.origin`，新增标记时同步更新 README。
- 测试只使用独立命名的 NSPasteboard 和 `.work/` 下的数据库，不能读写用户历史或系统通用剪贴板。

## 本地化

- 用户可见文字一律通过 `L("中文原文", 参数...)`，中文原文即 key；`zh-Hans.lproj` 为空，直接显示 key。
- `L` 的第一个参数必须是字符串字面量，变量通过格式参数传入；`check-strings.sh` 会解析源码并强制检查。
- 新增或修改文案时同步编辑 `macOS/Resources/en.lproj/Localizable.strings`，格式说明符（`%@`、`%d`、`%ld`、位置参数）必须一致，未使用的英文条目也会被报错。
- 运行时切换语言会重建面板、菜单和设置窗口（`AppDelegate.changeLanguage`）。面板还原原查询、历史或收藏模式及仍存在的选中项，设置窗口保留页签。新增长期存在的界面对象时，确认它会随之重建或刷新文字。

## 常见改动方式

- **新增偏好**：在 `AppSettings` 增加 `Key` 和带校验的属性（值不变时不要调用 `save`）→ 在 `AppDelegate.settingsChanged` 处理 → 在 `SettingsPanes.page(for:)` 加控件、在 `refresh(_:)` 回填 → 在 `WindowAndSettingsTests.settingsAndLanguage` 补断言。
- **新增面板快捷键**：在 `PanelShortcut` 声明键值、修饰键和文案，在 `PanelKeyRouting` / `PanelKeyRouter` 接入动作，并检查 `KeyboardSettings.validate` 的保留组合；同步更新 README。
- **新增剪贴板类型**：需要同时修改 `Payload`、`Content`、`RecordHeader.kind`、指纹、存储列和读写路径，这属于数据格式变更，见上文。
- **错误处理**：抛出 `AppError(L("…"), code: .xxx)`，由调用方通过 `onError` / `report` 写日志；不要静默吞掉错误（`HistoryDatabase.reclaimFreePages` 这类尽力而为的清理除外）。

## 测试约定

- `Tests/ClipNestCoreTests/` 提供无需窗口或剪贴板服务的 SwiftPM 用例，使用项目下的独立测试库。原生测试入口是 `macOS/Tests/Tests.swift` 的 `cases` 列表，每个具名用例拿到独立目录，失败后继续执行并在最后汇总。新增原生用例需加入该列表。
- `macOS/Tests/Fixtures/*.txt` 是冻结的源码快照，只作为真实文本样本，**不要随源码同步更新**。
- `StorageMetadataTests.swift` 以冻结的 v2、v3、v4 表结构、逐列认证格式和固定文件指纹创建独立数据库，以 v4 作为当前结构基线，验证迁移、原位读取、归档、重复收录、OCR 三种状态与失败回滚。后续版本继续覆盖旧库升级路径。
- 面板交互测试驱动真实窗口和事件循环（`PanelTests.wait`），新增 UI 测试时复用它，不要用 `sleep`。

## 发布

- 版本号在 `macOS/Info.plist`：`CFBundleShortVersionString`（展示版本）和 `CFBundleVersion`（每次发布递增的整数）。
- 默认临时签名；固定本地身份的方法见 README。公开分发需要 Developer ID 签名和公证，目前未接入。
- 行为变化时同步更新 README 的使用说明，并在 `CHANGELOG.md` 的“未发布”下记一条。发布时把“未发布”改为版本号、`CFBundleVersion` 与日期。
- 验证结论按日期倒序写入 `docs/VERIFICATION.md`，注明运行环境、通过的检查和未验证项。
