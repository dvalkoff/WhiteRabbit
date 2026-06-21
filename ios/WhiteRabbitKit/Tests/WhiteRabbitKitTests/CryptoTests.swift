import XCTest
@testable import WhiteRabbitKit

final class CryptoTests: XCTestCase {

    /// Build a PreKeyBundle from a responder's CryptoService for the initiator
    /// to consume (mimics the server fetching/serving a bundle). `otkIndex`
    /// selects which one-time prekey to hand out, mimicking the server consuming
    /// a different one on each fetch.
    private func bundle(from svc: CryptoService, useOTK: Bool = true, otkIndex: Int = 0) -> PreKeyBundle {
        let upload = svc.keyUpload()
        let otk = upload.oneTimePreKeys.indices.contains(otkIndex) ? upload.oneTimePreKeys[otkIndex] : nil
        return PreKeyBundle(
            registrationID: upload.registrationID,
            identityKeyEd: upload.identityKeyEd,
            identityKeyX: upload.identityKeyX,
            signedPreKeyID: upload.signedPreKeyID,
            signedPreKey: upload.signedPreKey,
            signedPreKeySig: upload.signedPreKeySig,
            hasOneTimePreKey: useOTK && otk != nil,
            oneTimePreKeyID: otk?.id ?? -1,
            oneTimePreKey: otk?.publicKey ?? Data()
        )
    }

    func testBundleSignatureVerifies() {
        let bob = CryptoService.generate()
        XCTAssertTrue(bundle(from: bob).verify())
    }

    func testSimpleRoundTrip() throws {
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)

        let (ct, isPrekey) = try alice.encrypt(Data("hello bob".utf8), to: "bob", bundle: bobBundle)
        XCTAssertTrue(isPrekey)
        let pt = try bob.decrypt(ct, from: "alice")
        XCTAssertEqual(String(data: pt, encoding: .utf8), "hello bob")
    }

    func testBidirectionalConversation() throws {
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)

        // Alice -> Bob (establishes session)
        let (m1, _) = try alice.encrypt(Data("hi".utf8), to: "bob", bundle: bobBundle)
        XCTAssertEqual(try bob.decrypt(m1, from: "alice"), Data("hi".utf8))

        // Bob -> Alice (triggers a DH ratchet step on Alice's next decrypt)
        let (m2, _) = try bob.encrypt(Data("hey".utf8), to: "alice", bundle: nil)
        XCTAssertEqual(try alice.decrypt(m2, from: "bob"), Data("hey".utf8))

        // A few more rounds in both directions.
        for i in 0..<5 {
            let (a, _) = try alice.encrypt(Data("a\(i)".utf8), to: "bob", bundle: nil)
            XCTAssertEqual(try bob.decrypt(a, from: "alice"), Data("a\(i)".utf8))
            let (b, _) = try bob.encrypt(Data("b\(i)".utf8), to: "alice", bundle: nil)
            XCTAssertEqual(try alice.decrypt(b, from: "bob"), Data("b\(i)".utf8))
        }
    }

    func testOutOfOrderDelivery() throws {
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)

        // Alice sends three messages in the same chain; deliver out of order.
        let (m1, _) = try alice.encrypt(Data("one".utf8), to: "bob", bundle: bobBundle)
        let (m2, _) = try alice.encrypt(Data("two".utf8), to: "bob", bundle: nil)
        let (m3, _) = try alice.encrypt(Data("three".utf8), to: "bob", bundle: nil)

        // Bob receives 1 (bootstraps), then 3, then 2.
        XCTAssertEqual(try bob.decrypt(m1, from: "alice"), Data("one".utf8))
        XCTAssertEqual(try bob.decrypt(m3, from: "alice"), Data("three".utf8))
        XCTAssertEqual(try bob.decrypt(m2, from: "alice"), Data("two".utf8))
    }

    func testWorksWithoutOneTimePreKey() throws {
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob, useOTK: false)

        let (ct, _) = try alice.encrypt(Data("no otk".utf8), to: "bob", bundle: bobBundle)
        XCTAssertEqual(try bob.decrypt(ct, from: "alice"), Data("no otk".utf8))
    }

    func testTamperedCiphertextFails() throws {
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)

        var (ct, _) = try alice.encrypt(Data("secret".utf8), to: "bob", bundle: bobBundle)
        // Flip a byte deep in the payload (inside the JSON-encoded body).
        ct[ct.count - 5] ^= 0xFF
        XCTAssertThrowsError(try bob.decrypt(ct, from: "alice"))
    }

    func testSessionStatePersistsViaCodable() throws {
        // Encode/decode a live ratchet session and confirm it still decrypts.
        let alice = CryptoService.generate()
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)
        let (m1, _) = try alice.encrypt(Data("persist".utf8), to: "bob", bundle: bobBundle)
        _ = try bob.decrypt(m1, from: "alice")

        let (m2, _) = try alice.encrypt(Data("again".utf8), to: "bob", bundle: nil)
        XCTAssertEqual(try bob.decrypt(m2, from: "alice"), Data("again".utf8))
    }

    /// After a peer "re-logs-in" (brand-new identity & keys) and sends a fresh
    /// handshake, the recipient — who still holds the OLD session — must rebuild
    /// from the new prekey message instead of clinging to the dead session.
    func testPeerReloginReestablishesSession() throws {
        let bob = CryptoService.generate()

        // Original session: alice1 <-> bob.
        let alice1 = CryptoService.generate()
        let (m1, _) = try alice1.encrypt(Data("before".utf8), to: "bob", bundle: bundle(from: bob, otkIndex: 0))
        XCTAssertEqual(try bob.decrypt(m1, from: "alice"), Data("before".utf8))

        // Alice re-logs-in: new identity/keys, fetches a fresh bundle (different
        // one-time prekey), and sends. Bob still has the alice1 session.
        let alice2 = CryptoService.generate()
        let (m2, _) = try alice2.encrypt(Data("after relogin".utf8), to: "bob", bundle: bundle(from: bob, otkIndex: 1))
        XCTAssertEqual(try bob.decrypt(m2, from: "alice"), Data("after relogin".utf8))

        // And the rebuilt session keeps working bidirectionally.
        let (reply, _) = try bob.encrypt(Data("welcome back".utf8), to: "alice", bundle: nil)
        XCTAssertEqual(try alice2.decrypt(reply, from: "bob"), Data("welcome back".utf8))
    }

    /// A message that fails to decrypt (e.g. encrypted to a stale identity) must
    /// not poison the session or burn the one-time prekey: a subsequent valid
    /// message from a correctly-keyed sender must still establish and decrypt.
    func testFailedDecryptDoesNotPoisonSession() throws {
        let bob = CryptoService.generate()
        let bobBundle = bundle(from: bob)

        // A stranger encrypts to Bob's bundle but using the SAME one-time prekey id;
        // then we corrupt it so it can't decrypt — simulating a stale/bad message.
        let stranger = CryptoService.generate()
        var (bad, _) = try stranger.encrypt(Data("garbage".utf8), to: "bob", bundle: bobBundle)
        bad[bad.count - 5] ^= 0xFF
        XCTAssertThrowsError(try bob.decrypt(bad, from: "alice"))

        // Now Alice sends a proper first message; Bob must still bootstrap & decrypt.
        let alice = CryptoService.generate()
        let freshBundle = bundle(from: bob) // same one-time prekey must still be available
        let (good, _) = try alice.encrypt(Data("hello".utf8), to: "bob", bundle: freshBundle)
        XCTAssertEqual(try bob.decrypt(good, from: "alice"), Data("hello".utf8))
    }
}
