# ClipNest 分发与上架指南

本文记录将 ClipNest 分发给其他用户的操作步骤，以及未来如需上架 Mac App Store 时针对当前代码库的适配清单。日常本地安装见 [README.md](../README.md)。

## 分发方式对比

| 方式 | 费用 | Gatekeeper / 权限体验 | 适用场景 |
| --- | --- | --- | --- |
| 临时签名 ZIP | 免费 | 首次需去隔离属性；每次更新后辅助功能需 `−` 移除再 `+` 重加 | 少数熟人内测 |
| 独立分发（Developer ID + 公证） | Apple Developer 付费账号（$99/年） | 零拦截直接打开；升级自动保留辅助功能与钥匙串授权 | **推荐**：公开分发、保留完整功能 |
| Mac App Store（沙箱版） | 同一个 Apple Developer 付费账号 | 商店分发自动更新；需补 App Sandbox 适配并通过苹果审核 | 面向大众商店分发或收费 |

---

## 一、小范围试用（无付费账号）

1. 使用临时签名构建通用包（不要用个人 `Apple Development` 证书发给别人）：
   ```sh
   CODESIGN_IDENTITY=- bash macOS/build.sh
   ```
2. 分发 `artifacts/macos/ClipNest-macOS-universal.zip`。
3. 对方解压拖入 `/Applications` 后，执行一次去隔离属性再打开：
   ```sh
   xattr -dr com.apple.quarantine /Applications/ClipNest.app
   ```

---

## 二、独立公开发布（Developer ID 签名 + Apple 公证）

独立分发无需开启 App Sandbox，完整保留当前全部功能（包括文件存在性校验与默认直接粘贴）。

### 1. 准备证书

- 加入 Apple Developer Program，在开发者后台或 Xcode 中创建并安装 **Developer ID Application** 证书到登录钥匙串。
- 始终保持相同的 `TeamIdentifier` 与 `CFBundleIdentifier`（`com.clipnest.mac`），避免用户升级后出现辅助功能或钥匙串权限失效。

### 2. 开启 Hardened Runtime 与时间戳签名

公证要求签名附带 `--options runtime --timestamp`。发布时调整 `macOS/build.sh`（或新增独立 `macOS/release.sh`）：

```sh
codesign --force --options runtime --timestamp \
  --sign "$CODESIGN_IDENTITY" \
  --identifier "$identifier" \
  artifacts/macos/ClipNest.app
```

> ClipNest 仅使用系统框架、无第三方动态库，通常不需要额外的 Hardened Runtime 例外 entitlements；启用后需实机复测全局热键、Vision OCR、钥匙串与直接粘贴。

### 3. 提交 Apple 公证与装订票据

```sh
# 首次保存公证凭据到本机钥匙串（App 专用密码或 App Store Connect API Key）
xcrun notarytool store-credentials "clipnest-notary" \
  --apple-id "<Apple ID>" --team-id "<Team ID>" --password "<App 专用密码>"

# 提交 zip 公证并等待结果
xcrun notarytool submit artifacts/macos/ClipNest-macOS-universal.zip \
  --keychain-profile "clipnest-notary" --wait

# 将公证票据装订到 .app（支持离线校验）
xcrun stapler staple artifacts/macos/ClipNest.app

# 本地校验 Gatekeeper（应输出 accepted / Notarized Developer ID）
spctl -a -vvv -t exec artifacts/macos/ClipNest.app
```

装订完成后，重新把 `artifacts/macos/ClipNest.app` 打包为最终 `.zip` 或 `.dmg` 发布到 GitHub Releases / Homebrew Cask。

### 4. 账号与证书到期影响

- **已发布的旧版本不会失效**：只要签名时带了 `--timestamp` 并完成公证装订，即便付费账号停续或 5 年后证书自然过期，已发布的安装包依然可正常安装运行（除非证书被主动吊销）。
- **付费账号未续费期间**：无法提交新版本公证、无法续签/新申请证书；若上架了 Mac App Store，商店内会暂时下架。续费同一账号后恢复全部能力，且 `TeamIdentifier` 不变。

---

## 三、后续上架 Mac App Store 适配清单

独立版与 App Store 版可并存，建议保留当前独立版构建不变，另行通过编译条件（例如 `-DAPP_STORE`）与独立打包脚本（如 `macOS/release-mas.sh`）输出商店版，避免影响独立版行为。

### 1. 代码库现状审计

**已天然兼容 App Sandbox（无需改动）：**
- **数据目录**：`macOS/Sources/Core/AppPaths.swift` 使用 `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`，开启沙箱后系统自动重定向至 `~/Library/Containers/com.clipnest.mac/Data/Library/Application Support/ClipNest/`。
- **文件选择器**：背景图片选择（`macOS/Sources/PanelBackgroundControls.swift`）与忽略应用选择（`macOS/Sources/SettingsPanes.swift`）均通过 `NSOpenPanel` 获取用户主动授权的只读文件。
- **登录启动**：`macOS/Sources/SystemAccess.swift` 使用 `SMAppService.mainApp`，原生支持沙箱。
- **直接粘贴机制**：`macOS/Sources/Paster.swift` 使用 `CGEvent.post(tap: .cgSessionEventTap)` 投递 `⌘V`，沙箱应用在用户手动开启辅助功能权限后仍可正常工作（参考 Maccy 方案），无权限时会自动退化为仅复制。

**开启 App Sandbox 前必须修改的项：**

- [ ] **剪贴板文件记录回填（`macOS/Sources/ClipboardAccess.swift`）**：
  - 当前 `write(.files(paths))` 会调用 `FileManager.default.attributesOfItem(atPath: path)` 校验源文件存在。
  - 在沙箱内无权访问容器外的任意路径，该调用会抛权限错误导致文件记录无法复制。
  - 适配方案：在 `APP_STORE`（或沙箱）构建下跳过对容器外路径的 `attributesOfItem` 校验，直接写入 `fileURL` 到剪贴板（并在沙箱环境下实机验证访达粘贴文件行为）。
- [ ] **新增沙箱权限文件（如 `macOS/ClipNest-MAS.entitlements`）**：
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.files.user-selected.read-only = true`
- [ ] **补齐 `macOS/Info.plist` 的 App Store 字段**：
  - `LSApplicationCategoryType`（如 `public.app-category.productivity`）
  - `ITSAppUsesNonExemptEncryption`（按实际情况申报：应用使用 `CryptoKit` AES-GCM 加密本地数据库，需同步在 App Store Connect 填写出口合规说明）
  - `NSHumanReadableCopyright`（建议补充）
- [ ] **审视默认直接粘贴策略**：
  - 评估在 `APP_STORE` 构建中是否将 `AppSettings.directPaste` 默认改为 `false`（用户勾选开启时再请求辅助功能权限），确保审核员无辅助功能权限时首次使用体验顺畅、减少审核追问。
- [ ] **复查非标准目录应用元数据读取（`macOS/Sources/Core/AppMetadataCache.swift`）**：
  - 实机确认沙箱下读取 `/Applications` 与用户目录应用的名称、图标回退是否符合预期。
- [ ] **数据隔离说明**：
  - 沙箱容器的数据目录与钥匙串域独立于非沙箱版；若用户从独立版迁到商店版，不会自动继承旧历史与密钥，必要时在文档中注明。

### 2. Apple 后台与提审步骤

- [ ] 在 Apple Developer 注册 App ID（`com.clipnest.mac`），准备：
  - **Apple Distribution** 证书（签名 `.app`）
  - **Mac Installer Distribution** 证书（签名 `.pkg`）
  - **Mac App Store Provisioning Profile**（打包时放入 `ClipNest.app/Contents/embedded.provisionprofile`）
- [ ] 使用 `--entitlements` 签名 `.app`，再通过 `productbuild` 打成 `.pkg`：
  ```sh
  productbuild --component artifacts/macos/ClipNest.app /Applications \
    --sign "3rd Party Mac Developer Installer: <Team>" \
    artifacts/macos/ClipNest-MAS.pkg
  ```
- [ ] 在 App Store Connect 创建应用，补齐商店文案、截图、隐私政策 URL 与隐私标签（声明数据仅存本机、不收集上传）。
- [ ] 在审核备注中说明剪贴板历史功能用途，以及可选“直接粘贴”为何需要用户手动授予辅助功能权限。
- [ ] 通过 Transporter 或 `xcrun altool` 上传 `.pkg` 并提交审核。

---

## 四、排查备忘：辅助功能“开关已开但仍未授权”

- macOS 的辅助功能权限（TCC）绑定的是代码签名要求（`csreq`）。从临时签名切到正式证书、或更换证书后，系统设置里可能依然显示蓝色开启，但 `AXIsProcessTrusted()` 返回 `false`。
- 仅关掉再打开开关不会更新旧 `csreq`，需在「系统设置 → 隐私与安全 → 辅助功能」中点 **`−` 移除** 后重新 **`+` 添加**，或执行：
  ```sh
  tccutil reset Accessibility com.clipnest.mac
  ```
  再重新勾选。切换为固定证书（如 `Developer ID`）后，后续同证书版本更新不会再触发此问题。
