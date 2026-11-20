// The Ed25519 key that signs Kalos's block list updates, kept in the login Keychain and never printed or exported.
// Separate from the Sparkle key. Run by publish-blocklists.sh:
//
//   swift blocklist-key.swift make-key                    make the key once; prints only the public key
//   swift blocklist-key.swift public-key                  the public key, for Sources/PaneCore/BlockListKey.swift
//   swift blocklist-key.swift sign <file> <out.sig>       sign with the Keychain key (appends when <out.sig> exists, for a rotation)
//   swift blocklist-key.swift sign-throwaway <file> <out.sig> <out.pub>
//                                                         sign with a key made in memory and dropped (dry runs; no Keychain)
//   swift blocklist-key.swift verify <file> <sig> <public key base64>
import CryptoKit
import Foundation
import Security

let service = "Kalos block lists"
let account = "kalos-blocklists"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("blocklist-key: \(message)\n".utf8))
    exit(1)
}

func query() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func storedKey() -> Curve25519.Signing.PrivateKey {
    var search = query()
    search[kSecReturnData as String] = true
    var found: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &found)
    guard status == errSecSuccess, let raw = found as? Data else {
        fail(status == errSecItemNotFound ? "no key in the Keychain; run publish-blocklists.sh --make-key first" : "Keychain error \(status)")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("the Keychain item is not an Ed25519 key") }
    return key
}

func sign(_ key: Curve25519.Signing.PrivateKey, file: String, out: String) {
    guard let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file)") }
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    var all = FileManager.default.contents(atPath: out) ?? Data()
    all.append(signature)
    guard FileManager.default.createFile(atPath: out, contents: all) else { fail("cannot write \(out)") }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "make-key":
    var exists = query()
    exists[kSecReturnAttributes as String] = true
    guard SecItemCopyMatching(exists as CFDictionary, nil) == errSecItemNotFound else {
        fail("a key is already in the Keychain; a second one would orphan every Kalos that trusts the first")
    }
    let key = Curve25519.Signing.PrivateKey()
    var add = query()
    add[kSecValueData as String] = key.rawRepresentation
    add[kSecAttrLabel as String] = "Kalos block list signing key"
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Keychain error \(status)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(storedKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let rest = Array(args.dropFirst())
    guard rest.count == 2 else { fail("sign <file> <out.sig>") }
    sign(storedKey(), file: rest[0], out: rest[1])
case "sign-throwaway":
    let rest = Array(args.dropFirst())
    guard rest.count == 3 else { fail("sign-throwaway <file> <out.sig> <out.pub>") }
    let key = Curve25519.Signing.PrivateKey()
    sign(key, file: rest[0], out: rest[1])
    guard FileManager.default.createFile(atPath: rest[2], contents: Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8)) else {
        fail("cannot write \(rest[2])")
    }
case "verify":
    let rest = Array(args.dropFirst())
    guard rest.count == 3, let data = FileManager.default.contents(atPath: rest[0]), let signatures = FileManager.default.contents(atPath: rest[1]),
          let raw = Data(base64Encoded: rest[2].trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("verify <file> <sig> <public key base64>") }
    guard signatures.count % 64 == 0, !signatures.isEmpty else { fail("not a signature file") }
    let good = stride(from: 0, to: signatures.count, by: 64).contains { key.isValidSignature(signatures.subdata(in: $0..<$0 + 64), for: data) }
    guard good else { fail("the signature does not match") }
    print("signature ok")
default:
    fail("make-key | public-key | sign <file> <out.sig> | sign-throwaway <file> <out.sig> <out.pub> | verify <file> <sig> <key>")
}
