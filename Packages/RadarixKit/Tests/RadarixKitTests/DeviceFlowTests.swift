import Foundation
import Testing
@testable import RadarixKit

private actor SleepRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

private let codeURL = "https://github.com/login/device/code"
private let tokenURL = "https://github.com/login/oauth/access_token"
private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

private func makeFlow(
    clientID: String = "client123",
    transport: StubTransport,
    recorder: SleepRecorder = SleepRecorder(),
    now: @escaping @Sendable () -> Date = { fixedNow }
) -> DeviceFlow {
    DeviceFlow(clientID: clientID, transport: transport, sleep: { await recorder.record($0) }, now: now)
}

private func code(interval: TimeInterval = 5, expiresIn: TimeInterval = 900) -> DeviceCode {
    DeviceCode(
        userCode: "ABCD-1234",
        verificationURI: URL(string: "https://github.com/login/device")!,
        deviceCode: "dev123",
        interval: interval,
        expiresAt: fixedNow.addingTimeInterval(expiresIn)
    )
}

@Suite struct DeviceFlowTests {
    @Test func startPostsClientIDAndScopes() async throws {
        let stub = StubTransport()
        await stub.enqueue(codeURL, status: 200, body: """
        {"device_code":"dev123","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":7}
        """)
        let result = try await makeFlow(transport: stub).start()

        #expect(result.userCode == "ABCD-1234")
        #expect(result.deviceCode == "dev123")
        #expect(result.interval == 7)
        #expect(result.verificationURI.absoluteString == "https://github.com/login/device")
        #expect(result.expiresAt == fixedNow.addingTimeInterval(900))

        let request = try #require(await stub.sent.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == codeURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=client123&scope=repo%20read%3Aorg")
    }

    @Test func startDefaultsIntervalToFive() async throws {
        let stub = StubTransport()
        await stub.enqueue(codeURL, status: 200, body: """
        {"device_code":"d","user_code":"U","verification_uri":"https://github.com/login/device","expires_in":60}
        """)
        #expect(try await makeFlow(transport: stub).start().interval == 5)
    }

    @Test func emptyClientIDIsNotConfigured() async throws {
        let stub = StubTransport()
        await #expect(throws: DeviceFlowError.notConfigured) {
            try await makeFlow(clientID: "", transport: stub).start()
        }
        #expect(await stub.sent.isEmpty)
    }

    @Test func startNon200ThrowsHTTP() async throws {
        let stub = StubTransport()
        await stub.enqueue(codeURL, status: 500)
        await #expect(throws: DeviceFlowError.http(500)) {
            try await makeFlow(transport: stub).start()
        }
    }

    @Test func pollsUntilTokenHonoringSlowDown() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"slow_down"}"#)
        await stub.enqueue(tokenURL, status: 200, body: #"{"access_token":"gho_abc","token_type":"bearer"}"#)
        let recorder = SleepRecorder()
        let token = try await makeFlow(transport: stub, recorder: recorder).waitForToken(code())

        #expect(token == "gho_abc")
        #expect(await recorder.values == [5, 10])

        let request = try #require(await stub.sent.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=client123&device_code=dev123&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }

    @Test func slowDownUsesResponseIntervalWhenGiven() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"slow_down","interval":20}"#)
        await stub.enqueue(tokenURL, status: 200, body: #"{"access_token":"t"}"#)
        let recorder = SleepRecorder()
        _ = try await makeFlow(transport: stub, recorder: recorder).waitForToken(code())
        #expect(await recorder.values == [5, 20])
    }

    @Test func pendingKeepsInterval() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"authorization_pending"}"#)
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"authorization_pending"}"#)
        await stub.enqueue(tokenURL, status: 200, body: #"{"access_token":"t"}"#)
        let recorder = SleepRecorder()
        _ = try await makeFlow(transport: stub, recorder: recorder).waitForToken(code())
        #expect(await recorder.values == [5, 5, 5])
    }

    @Test func expiredTokenThrowsExpired() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"expired_token"}"#)
        await #expect(throws: DeviceFlowError.expired) {
            try await makeFlow(transport: stub).waitForToken(code())
        }
    }

    @Test func passedDeadlineThrowsExpiredWithoutPolling() async throws {
        let stub = StubTransport()
        await #expect(throws: DeviceFlowError.expired) {
            try await makeFlow(transport: stub).waitForToken(code(expiresIn: 0))
        }
        #expect(await stub.sent.isEmpty)
    }

    @Test func accessDeniedThrowsDenied() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"access_denied"}"#)
        await #expect(throws: DeviceFlowError.denied) {
            try await makeFlow(transport: stub).waitForToken(code())
        }
    }

    @Test func unknownErrorThrowsHTTP() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 200, body: #"{"error":"incorrect_client_credentials"}"#)
        await #expect(throws: DeviceFlowError.http(200)) {
            try await makeFlow(transport: stub).waitForToken(code())
        }
    }

    @Test func non200ThrowsHTTP() async throws {
        let stub = StubTransport()
        await stub.enqueue(tokenURL, status: 503)
        await #expect(throws: DeviceFlowError.http(503)) {
            try await makeFlow(transport: stub).waitForToken(code())
        }
    }

    @Test func cancellationFromSleepPropagates() async throws {
        let stub = StubTransport()
        let flow = DeviceFlow(clientID: "c", transport: stub, sleep: { _ in throw CancellationError() }, now: { fixedNow })
        await #expect(throws: CancellationError.self) {
            try await flow.waitForToken(code())
        }
    }
}
