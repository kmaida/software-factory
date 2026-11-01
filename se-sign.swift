// se-sign: the factory's Keycard client-assertion signer, backed by the Secure Enclave.
// Build:  swiftc -O -o se-sign se-sign.swift && codesign -s - se-sign
//   keygen <blob>   create a P-256 key in the Secure Enclave; write its opaque representation to <blob> (0400, O_EXCL).
//                   The blob is usable only by this machine's enclave; it is not the private key.
//   pubkey <blob>   print the public key as a JWK (one line) for docs/jwks.json; kid is the RFC 7638 thumbprint
//   pubpem <blob>   print the public key as PEM (for checking the JWK with openssl)
//   sign   <blob>   read stdin (at most 64 KiB), write the 64-byte r||s ES256 signature to stdout (what JWS wants, no DER)
// Exit 2 on any failure with the reason on stderr. stdout is meaningful only on exit 0: the caller writes it to a file
// and uses the file only when the exit status is 0.
// stdin/stdout go through POSIX read/write: FileHandle raises ObjC exceptions on I/O errors, which Swift can't catch.
// ponytail: default access control (AfterFirstUnlockThisDeviceOnly, no flags): no biometric, no presence, usable
// unattended once the machine has been unlocked since boot. Loading never shows UI (interactionNotAllowed), so a
// substituted blob with a presence requirement fails instead of waiting for a human.
import CryptoKit
import Foundation
import LocalAuthentication

let MAX_BLOB = 4096, MAX_INPUT = 65536

func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}
func die(_ msg: String) -> Never {
    _ = writeFully(2, Array(("se-sign: " + msg + "\n").utf8))
    exit(2)
}
func errnoText() -> String { String(cString: strerror(errno)) }
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func readBounded(_ fd: Int32, max: Int, _ what: String) -> Data {
    var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n < 0 { die("\(what): read failed: \(errnoText())") }
        if n == 0 { return out }
        out.append(contentsOf: buf[0..<n])
        if out.count > max { die("\(what): more than \(max) bytes") }
    }
}
func readBlob(_ path: String) -> Data {
    // No symlink, must be a regular file, bounded size, never blocks on a FIFO.
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { die("cannot open \(path): \(errnoText())") }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else { die("cannot stat \(path): \(errnoText())") }
    guard (st.st_mode & S_IFMT) == S_IFREG else { die("\(path) is not a regular file") }
    guard st.st_size > 0 && st.st_size <= MAX_BLOB else { die("\(path) has an implausible size \(st.st_size)") }
    return readBounded(fd, max: MAX_BLOB, path)
}
func tryLoad(_ blob: Data) throws -> SecureEnclave.P256.Signing.PrivateKey {
    let ctx = LAContext(); ctx.interactionNotAllowed = true
    return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: ctx)
}
func load(_ path: String) -> SecureEnclave.P256.Signing.PrivateKey {
    do { return try tryLoad(readBlob(path)) } catch { die("cannot load key from \(path): \(error)") }
}
func jwkParts(_ key: SecureEnclave.P256.Signing.PrivateKey) -> (x: String, y: String, kid: String) {
    let x963 = Data(key.publicKey.x963Representation)   // rebased copy: 0x04 || X || Y, 65 bytes, indices from 0
    guard x963.count == 65 else { die("unexpected public key length \(x963.count)") }
    let x = b64url(x963[1..<33]), y = b64url(x963[33..<65])
    // RFC 7638: SHA-256 of the required members in lexicographic order, no whitespace.
    let thumb = Data(#"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#.utf8)
    return (x, y, b64url(Data(SHA256.hash(data: thumb))))
}
func out(_ d: Data) { if !writeFully(1, [UInt8](d)) { die("stdout: write failed: \(errnoText())") } }

signal(SIGPIPE, SIG_IGN)   // a closed stdout is a write error (exit 2), not a silent kill
let args = CommandLine.arguments
guard args.count == 3 else { die("usage: se-sign keygen|pubkey|pubpem|sign <blob>") }
let path = args[2]
switch args[1] {
case "keygen":
    guard SecureEnclave.isAvailable else { die("no Secure Enclave on this machine") }
    // Open first, exclusively, never through a symlink, mode applied at creation: an existing or partial file is a
    // refusal, and a bad path fails before an orphan key is generated in the enclave.
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o400)
    guard fd >= 0 else { die("cannot create \(path): \(errnoText())") }
    func fail(_ msg: String) -> Never { let e = errnoText(); close(fd); unlink(path); die("\(msg): \(e)") }
    let key: SecureEnclave.P256.Signing.PrivateKey
    do { key = try SecureEnclave.P256.Signing.PrivateKey() } catch { fail("keygen failed: \(error)") }
    guard writeFully(fd, [UInt8](key.dataRepresentation)) else { fail("cannot write \(path)") }
    guard close(fd) == 0 else { unlink(path); die("cannot close \(path): \(errnoText())") }
    // Read the blob back, check it names the same key and can sign, so a bad blob is caught now, not at the first
    // token request. Any failure removes the blob so keygen can be retried.
    do {
        let again = try tryLoad(readBlob(path))
        guard again.publicKey.rawRepresentation == key.publicKey.rawRepresentation else { throw NSError(domain: "se-sign", code: 1, userInfo: [NSLocalizedDescriptionKey: "public key differs"]) }
        let probe = Data("se-sign keygen self-test".utf8)
        guard key.publicKey.isValidSignature(try again.signature(for: probe), for: probe) else { throw NSError(domain: "se-sign", code: 2, userInfo: [NSLocalizedDescriptionKey: "signature does not verify"]) }
    } catch { unlink(path); die("blob round trip failed: \(error)") }
case "pubkey":
    let p = jwkParts(load(path))
    out(Data((#"{"kty":"EC","crv":"P-256","x":"\#(p.x)","y":"\#(p.y)","kid":"\#(p.kid)","use":"sig","alg":"ES256"}"# + "\n").utf8))
case "pubpem":
    out(Data((load(path).publicKey.pemRepresentation + "\n").utf8))
case "sign":
    let key = load(path)
    let input = readBounded(0, max: MAX_INPUT, "stdin")
    guard !input.isEmpty else { die("nothing to sign on stdin") }
    let sig: Data
    do { sig = try key.signature(for: input).rawRepresentation } catch { die("sign failed: \(error)") }
    guard sig.count == 64 else { die("unexpected signature length \(sig.count)") }
    out(sig)
default:
    die("unknown command \(args[1]); use keygen, pubkey, pubpem or sign")
}
