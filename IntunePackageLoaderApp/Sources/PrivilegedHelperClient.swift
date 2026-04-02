import Foundation
import Security
import ServiceManagement

enum PrivilegedHelperClient {
    private static let installPath = "/Library/PrivilegedHelperTools/\(privilegedHelperLabel)"

    static func ensureBlessed() throws {
        if FileManager.default.fileExists(atPath: installPath) {
            return
        }

        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            throw helperError("Failed to create authorization reference (\(createStatus)).")
        }
        defer { AuthorizationFree(authRef, []) }

        var authItem = AuthorizationItem(
            name: kSMRightBlessPrivilegedHelper,
            valueLength: 0,
            value: nil,
            flags: 0
        )
        var rights = AuthorizationRights(count: 1, items: &authItem)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let copyStatus = AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
        guard copyStatus == errAuthorizationSuccess else {
            throw helperError("Authorization for helper installation failed (\(copyStatus)).")
        }

        var cfError: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd, privilegedHelperLabel as CFString, authRef, &cfError)
        if !blessed {
            let error = cfError?.takeRetainedValue()
            throw error ?? helperError("SMJobBless failed.")
        }
    }

    static func fetchStatus(rootDirectory: String) async throws -> Bool {
        let connection = makeConnection()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let finish = makeFinisher(connection: connection, continuation: continuation)
            let proxy = remoteProxy(for: connection, finish: finish)
            proxy.fetchMirrorStatus(rootDirectory) { isRunning, errorMessage in
                if let errorMessage {
                    finish(.failure(helperError(errorMessage)))
                } else {
                    finish(.success(isRunning))
                }
            }
        }
    }

    static func startMirror(rootDirectory: String) async throws {
        try ensureBlessed()

        try await performVoidCall { proxy, finish in
            proxy.startMirror(rootDirectory) { errorMessage in
                if let errorMessage {
                    finish(.failure(helperError(errorMessage)))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    static func stopMirror() async throws {
        try await performVoidCall { proxy, finish in
            proxy.stopMirror { errorMessage in
                if let errorMessage {
                    finish(.failure(helperError(errorMessage)))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    static func cleanupPackages(rootDirectory: String) async throws {
        try ensureBlessed()

        try await performVoidCall { proxy, finish in
            proxy.cleanupPackages(rootDirectory) { errorMessage in
                if let errorMessage {
                    finish(.failure(helperError(errorMessage)))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    private static func performVoidCall(
        operation: @escaping (IntunePackageMirrorHelperProtocol, @escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let connection = makeConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finish = makeFinisher(connection: connection, continuation: continuation)
            let proxy = remoteProxy(for: connection, finish: finish)
            operation(proxy, finish)
        }
    }

    private static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: privilegedHelperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: IntunePackageMirrorHelperProtocol.self)
        connection.resume()
        return connection
    }

    private static func makeFinisher<T>(
        connection: NSXPCConnection,
        continuation: CheckedContinuation<T, Error>
    ) -> (Result<T, Error>) -> Void {
        let lock = NSLock()
        var resumed = false

        connection.invalidationHandler = {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: helperError("Connection to privileged helper was invalidated."))
        }

        connection.interruptionHandler = {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: helperError("Connection to privileged helper was interrupted."))
        }

        return { result in
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            connection.invalidate()
            continuation.resume(with: result)
        }
    }

    private static func remoteProxy<T>(
        for connection: NSXPCConnection,
        finish: @escaping (Result<T, Error>) -> Void
    ) -> IntunePackageMirrorHelperProtocol {
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(error))
        }) as? IntunePackageMirrorHelperProtocol {
            return proxy
        }

        finish(.failure(helperError("Could not create privileged helper proxy.")))
        return FallbackProxy()
    }

    private static func helperError(_ description: String) -> NSError {
        NSError(
            domain: "IntunePackageLoader.PrivilegedHelper",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

private final class FallbackProxy: NSObject, IntunePackageMirrorHelperProtocol {
    func fetchMirrorStatus(_ rootDirectory: String, withReply reply: @escaping (Bool, String?) -> Void) {
        reply(false, "Could not create privileged helper proxy.")
    }

    func startMirror(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void) {
        reply("Could not create privileged helper proxy.")
    }

    func stopMirror(withReply reply: @escaping (String?) -> Void) {
        reply("Could not create privileged helper proxy.")
    }

    func cleanupPackages(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void) {
        reply("Could not create privileged helper proxy.")
    }
}
