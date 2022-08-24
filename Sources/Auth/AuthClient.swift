import Foundation
import Combine
import WalletConnectUtils
import WalletConnectPairing
import WalletConnectRelay


public class AuthClient {
    enum Errors: Error {
        case malformedPairingURI
        case unknownWalletAddress
        case noPairingMatchingTopic
    }
    private var authRequestPublisherSubject = PassthroughSubject<AuthRequest, Never>()
    public var authRequestPublisher: AnyPublisher<AuthRequest, Never> {
        authRequestPublisherSubject.eraseToAnyPublisher()
    }

    private var authResponsePublisherSubject = PassthroughSubject<(id: RPCID, result: Result<Cacao, AuthError>), Never>()
    public var authResponsePublisher: AnyPublisher<(id: RPCID, result: Result<Cacao, AuthError>), Never> {
        authResponsePublisherSubject.eraseToAnyPublisher()
    }

    public let socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never>

    private let appPairService: AppPairService
    private let appRequestService: AppRequestService
    private let appRespondSubscriber: AppRespondSubscriber

    private let walletPairService: WalletPairService
    private let walletRequestSubscriber: WalletRequestSubscriber
    private let walletRespondService: WalletRespondService
    private let cleanupService: CleanupService
    private let pairingStorage: WCPairingStorage
    private let pendingRequestsProvider: PendingRequestsProvider
    public let logger: ConsoleLogging

    private var account: Account?

    init(appPairService: AppPairService,
         appRequestService: AppRequestService,
         appRespondSubscriber: AppRespondSubscriber,
         walletPairService: WalletPairService,
         walletRequestSubscriber: WalletRequestSubscriber,
         walletRespondService: WalletRespondService,
         account: Account?,
         pendingRequestsProvider: PendingRequestsProvider,
         cleanupService: CleanupService,
         logger: ConsoleLogging,
         pairingStorage: WCPairingStorage,
         socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never>
) {
        self.appPairService = appPairService
        self.appRequestService = appRequestService
        self.walletPairService = walletPairService
        self.walletRequestSubscriber = walletRequestSubscriber
        self.walletRespondService = walletRespondService
        self.appRespondSubscriber = appRespondSubscriber
        self.account = account
        self.pendingRequestsProvider = pendingRequestsProvider
        self.cleanupService = cleanupService
        self.logger = logger
        self.pairingStorage = pairingStorage
        self.socketConnectionStatusPublisher = socketConnectionStatusPublisher

        setUpPublishers()
    }

    /// For wallet to establish a pairing and receive an authentication request
    /// Wallet should call this function in order to accept peer's pairing proposal and be able to subscribe for future authentication request.
    /// - Parameter uri: Pairing URI that is commonly presented as a QR code by a dapp or delivered with universal linking.
    ///
    /// Throws Error:
    /// - When URI is invalid format or missing params
    /// - When topic is already in use
    public func pair(uri: String) async throws {
        guard let pairingURI = WalletConnectURI(string: uri) else {
            throw Errors.malformedPairingURI
        }
        try await walletPairService.pair(pairingURI)
    }

    /// For a dapp to send an authentication request to a wallet
    /// - Parameter params: Set of parameters required to request authentication
    ///
    /// - Returns: Pairing URI that should be shared with wallet out of bound. Common way is to present it as a QR code.
    public func request(_ params: RequestParams) async throws -> String {
        logger.debug("Requesting Authentication")
        let uri = try await appPairService.create()
        try await appRequestService.request(params: params, topic: uri.topic)
        return uri.absoluteString
    }

    /// For a dapp to send an authentication request to a wallet
    /// - Parameter params: Set of parameters required to request authentication
    /// - Parameter topic: Pairing topic that wallet already subscribes for
    public func request(_ params: RequestParams, topic: String) async throws {
        logger.debug("Requesting Authentication on existing pairing")
        guard pairingStorage.hasPairing(forTopic: topic) else {
            throw Errors.noPairingMatchingTopic
        }
        try await appRequestService.request(params: params, topic: topic)
    }

    public func respond(requestId: RPCID, signature: CacaoSignature) async throws {
        guard let account = account else { throw Errors.unknownWalletAddress }
        try await walletRespondService.respond(requestId: requestId, signature: signature, account: account)
    }

    public func reject(requestId: RPCID) async throws {
        try await walletRespondService.respondError(requestId: requestId)
    }

    public func getPendingRequests() throws -> [AuthRequest] {
        guard let account = account else { throw Errors.unknownWalletAddress }
        return try pendingRequestsProvider.getPendingRequests(account: account)
    }

#if DEBUG
    /// Delete all stored data such as: pairings, keys
    ///
    /// - Note: Doesn't unsubscribe from topics
    public func cleanup() throws {
        try cleanupService.cleanup()
    }
#endif

    private func setUpPublishers() {
        appRespondSubscriber.onResponse = { [unowned self] (id, result) in
            authResponsePublisherSubject.send((id, result))
        }

        walletRequestSubscriber.onRequest = { [unowned self] request in
            authRequestPublisherSubject.send(request)
        }
    }
}
