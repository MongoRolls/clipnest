import Foundation
import CryptoKit
import Security

package enum KeyProvider {
    package static func historyKey(service: String = "com.clipnest.history") throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "history-key"]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw AppError(L("钥匙串密钥格式无效。"), code: .keychain) }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            throw AppError(L("读取钥匙串失败（%d）：%@。请解锁登录钥匙串并检查 ClipNest 的密钥访问权限。", status, detail), code: .keychain)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add = SecItemAdd(query.merging([kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else {
            let detail = SecCopyErrorMessageString(add, nil) as String? ?? String(add)
            throw AppError(L("保存钥匙串密钥失败（%d）：%@。请检查登录钥匙串是否可写。", add, detail), code: .keychain)
        }
        return key
    }
}
