import Foundation
import OSLog

private final class RomMDownloadProgressDelegate:
  NSObject,
  URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private static let minimumProgressInterval: TimeInterval = 0.25

  private let onProgress: @Sendable (RomMDownloadProgress) -> Void
  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var continuation:
    CheckedContinuation<(URL, URLResponse), any Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var downloadedFileURL: URL?
  private var fileMoveError: (any Error)?
  private var isCancelled = false
  private var isFinished = false
  private var lastProgressEmissionUptime: TimeInterval?

  init(
    configuration: URLSessionConfiguration,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) {
    self.configuration = configuration
    self.onProgress = onProgress
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "org.kennethreitz.RetroVault.rom-download"
        delegateQueue.qualityOfService = .utility

        let session = URLSession(
          configuration: configuration,
          delegate: self,
          delegateQueue: delegateQueue
        )
        let task = session.downloadTask(with: request)

        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()

        task.resume()
        if shouldCancel {
          task.cancel()
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func cancel() {
    lock.lock()
    isCancelled = true
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    let isComplete =
      totalBytesExpectedToWrite > 0
      && totalBytesWritten >= totalBytesExpectedToWrite
    if let lastProgressEmissionUptime,
      !isComplete,
      now - lastProgressEmissionUptime < Self.minimumProgressInterval
    {
      return
    }
    lastProgressEmissionUptime = now

    onProgress(
      RomMDownloadProgress(
        bytesReceived: totalBytesWritten,
        totalBytesExpected: totalBytesExpectedToWrite > 0
          ? totalBytesExpectedToWrite
          : nil
      )
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let retainedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: false)

    do {
      try FileManager.default.moveItem(at: location, to: retainedURL)
      lock.lock()
      downloadedFileURL = retainedURL
      lock.unlock()
    } catch {
      lock.lock()
      fileMoveError = error
      lock.unlock()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true

    let continuation = continuation
    let downloadedFileURL = downloadedFileURL
    let response = task.response
    let fileMoveError = fileMoveError
    self.continuation = nil
    self.task = nil
    self.session = nil
    lock.unlock()

    session.finishTasksAndInvalidate()

    if let error = fileMoveError ?? error {
      if let downloadedFileURL {
        try? FileManager.default.removeItem(at: downloadedFileURL)
      }
      continuation?.resume(throwing: error)
    } else if let downloadedFileURL, let response {
      continuation?.resume(returning: (downloadedFileURL, response))
    } else {
      continuation?.resume(throwing: RomMAPIError.invalidResponse)
    }
  }
}

final class URLSessionRomMClient: RomMClient, @unchecked Sendable {
  private let session: URLSession
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private let reachability: any RomMReachabilityRecording

  init(
    session: URLSession = .shared,
    reachability: any RomMReachabilityRecording = RomMReachability.shared
  ) {
    self.session = session
    decoder = JSONDecoder()
    encoder = JSONEncoder()
    self.reachability = reachability
  }

  func verifyServer(at serverURL: ServerURL) async throws {
    let request = URLRequest(url: serverURL.endpoint("api/heartbeat"))
    _ = try await data(for: request)
  }

  func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
    var request = URLRequest(url: serverURL.endpoint("api/client-tokens/exchange"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try encoder.encode(PairingCodeDTO(code: pairingCode.value))

    do {
      let data = try await data(for: request)
      let response = try decoder.decode(ClientTokenDTO.self, from: data)
      return try ClientToken(rawValue: response.rawToken)
    } catch RomMAPIError.notFound {
      // RomM returns 404 when a pairing code is unknown, expired, or
      // already consumed. The heartbeat check has already established
      // that this is a compatible RomM server.
      throw RomMAPIError.rejectedPairingCode
    } catch RomMAPIError.server(statusCode: 422) {
      throw RomMAPIError.rejectedPairingCode
    } catch is DecodingError {
      throw RomMAPIError.decoding(ClientTokenError.invalid)
    }
  }

  func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
    var request = URLRequest(url: serverURL.endpoint("api/users/me"))
    authorize(&request, with: token)

    let data = try await data(for: request)
    do {
      let user = try decoder.decode(UserDTO.self, from: data)
      return RomMUser(
        id: user.id,
        username: user.username,
        scopes: Set(user.oauthScopes)
      )
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
    var request = URLRequest(url: serverURL.endpoint("api/platforms"))
    authorize(&request, with: token)

    do {
      let data = try await data(for: request)
      return try decoder.decode([SystemDTO].self, from: data)
        .map {
          LibrarySystem(
            id: $0.id,
            name: $0.displayName,
            gameCount: $0.gameCount
          )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func collections(at serverURL: ServerURL, token: ClientToken) async throws -> [LibraryCollection]
  {
    async let regularData = authenticatedData(
      at: serverURL.endpoint("api/collections"),
      token: token
    )
    async let smartData = authenticatedData(
      at: serverURL.endpoint("api/collections/smart"),
      token: token
    )

    do {
      let (regular, smart) = try await (
        regularData,
        smartData
      )
      let regularCollections = try decoder.decode([CollectionDTO].self, from: regular)
        .map {
          LibraryCollection(
            id: .regular($0.id),
            name: $0.name,
            gameCount: $0.gameCount,
            isFavorite: $0.isFavorite,
            memberGameIDs: $0.gameIDs
          )
        }
      let smartCollections = try decoder.decode([CollectionDTO].self, from: smart)
        .map {
          LibraryCollection(
            id: .smart($0.id),
            name: $0.name,
            gameCount: $0.gameCount,
            isFavorite: $0.isFavorite,
            memberGameIDs: $0.gameIDs
          )
        }

      return (regularCollections + smartCollections)
        .sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    ordering: GamePageOrdering,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    var components = URLComponents(
      url: serverURL.endpoint("api/roms"),
      resolvingAgainstBaseURL: false
    )
    var queryItems = [
      URLQueryItem(name: "with_char_index", value: "false"),
      URLQueryItem(name: "with_filter_values", value: "false"),
      URLQueryItem(name: "with_rom_id_index", value: "false"),
      URLQueryItem(name: "with_files", value: "false"),
      URLQueryItem(
        name: "order_by",
        value: ordering == .identifier ? "id" : "name"
      ),
      URLQueryItem(name: "order_dir", value: "asc"),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]

    if let searchTerm, !searchTerm.isEmpty {
      queryItems.append(URLQueryItem(name: "search_term", value: searchTerm))
    }

    switch filter {
    case .allGames:
      break
    case .system(let id):
      queryItems.append(URLQueryItem(name: "platform_ids", value: String(id)))
    case .systems(let ids):
      queryItems.append(
        contentsOf: ids.sorted().map {
          URLQueryItem(name: "platform_ids", value: String($0))
        }
      )
    case .collection(.regular(let id)):
      queryItems.append(URLQueryItem(name: "collection_id", value: String(id)))
    case .collection(.smart(let id)):
      queryItems.append(URLQueryItem(name: "smart_collection_id", value: String(id)))
    case .collection(.virtual(let id)):
      queryItems.append(URLQueryItem(name: "virtual_collection_id", value: id))
    }

    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw RomMAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    authorize(&request, with: token)

    do {
      let data = try await data(for: request)
      let page = try decoder.decode(GamePageDTO.self, from: data)
      return GamePage(
        games: page.items.map { $0.gameSummary(serverURL: serverURL) },
        total: page.total,
        limit: page.limit,
        offset: page.offset
      )
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func gameIDsWithSaveData(
    _ kind: GameSaveDataKind,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> Set<Int> {
    let pageSize = 500
    var gameIDs: Set<Int> = []
    var offset = 0

    while true {
      var components = URLComponents(
        url: serverURL.endpoint("api/roms"),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [
        URLQueryItem(name: "with_char_index", value: "false"),
        URLQueryItem(name: "with_filter_values", value: "false"),
        URLQueryItem(name: "with_rom_id_index", value: "false"),
        URLQueryItem(name: "with_files", value: "false"),
        URLQueryItem(
          name: kind == .save ? "has_saves" : "has_states",
          value: "true"
        ),
        URLQueryItem(name: "limit", value: String(pageSize)),
        URLQueryItem(name: "offset", value: String(offset)),
      ]
      guard let url = components?.url else {
        throw RomMAPIError.invalidResponse
      }

      var request = URLRequest(url: url)
      authorize(&request, with: token)

      do {
        let data = try await data(for: request)
        let page = try decoder.decode(GamePageDTO.self, from: data)
        gameIDs.formUnion(page.items.map(\.id))

        guard page.offset + page.items.count < page.total else {
          return gameIDs
        }
        guard !page.items.isEmpty else {
          throw RomMAPIError.invalidResponse
        }
        offset = page.offset + page.items.count
      } catch let error as RomMAPIError {
        throw error
      } catch {
        throw RomMAPIError.decoding(error)
      }
    }
  }

  func gameDetails(
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDetails {
    var request = URLRequest(url: serverURL.endpoint("api/roms/\(gameID)"))
    authorize(&request, with: token)

    do {
      let data = try await data(for: request)
      return try decoder.decode(GameDetailsDTO.self, from: data)
        .gameDetails(serverURL: serverURL)
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func updateGameUserMetadata(
    _ metadata: GameUserMetadata,
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameUserMetadata {
    var request = URLRequest(
      url: serverURL.endpoint("api/roms/\(gameID)/props")
    )
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorize(&request, with: token)
    request.httpBody = try encoder.encode(
      GameUserMetadataUpdateDTO(metadata: metadata)
    )

    do {
      let data = try await data(for: request)
      return try decoder.decode(GameUserMetadataDTO.self, from: data)
        .gameUserMetadata
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func updateCollectionMembership(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> LibraryCollection {
    var request = URLRequest(
      url: serverURL.endpoint("api/collections/\(collectionID)/roms")
    )
    request.httpMethod = adding ? "POST" : "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorize(&request, with: token)
    request.httpBody = try encoder.encode(
      CollectionRomsRequestDTO(romIDs: gameIDs)
    )

    do {
      let data = try await self.data(for: request)
      let collection = try decoder.decode(CollectionDTO.self, from: data)
      return LibraryCollection(
        id: .regular(collection.id),
        name: collection.name,
        gameCount: collection.gameCount,
        isFavorite: collection.isFavorite,
        memberGameIDs: collection.gameIDs
      )
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    try await downloadGame(
      for: gameID,
      fileName: fileName,
      at: serverURL,
      token: token,
      onProgress: { _ in }
    )
  }

  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> RomMDownload {
    var request = URLRequest(
      url: serverURL.endpoint("api/roms/\(gameID)/content/\(fileName)")
    )
    authorize(&request, with: token)
    request.setValue(
      "application/octet-stream, application/zip;q=0.9, */*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    RetroVaultLog.network.debug(
      "GET \(request.url?.path ?? "", privacy: .public) (download)"
    )

    let temporaryFileURL: URL
    let response: URLResponse
    let progressDelegate = RomMDownloadProgressDelegate(
      configuration: session.configuration,
      onProgress: onProgress
    )

    do {
      onProgress(
        RomMDownloadProgress(
          bytesReceived: 0,
          totalBytesExpected: nil
        )
      )
      (temporaryFileURL, response) = try await progressDelegate.download(
        for: request
      )
    } catch let error as URLError {
      // URLSession reports a cancelled Swift task as URLError.cancelled
      // rather than CancellationError. Left alone it reads as a server
      // that could not be reached.
      guard error.code != .cancelled else {
        throw CancellationError()
      }
      reachability.recordFailure(RomMAPIError.transport(error))
      RetroVaultLog.network.error(
        "ROM download transport error \(error.code.rawValue, privacy: .public)"
      )
      throw RomMAPIError.transport(error)
    }

    do {
      reachability.recordServerAnswered()
      guard let httpResponse = response as? HTTPURLResponse else {
        throw RomMAPIError.invalidResponse
      }
      RetroVaultLog.network.debug(
        "GET \(request.url?.path ?? "", privacy: .public) → \(httpResponse.statusCode, privacy: .public) (download)"
      )
      if httpResponse.statusCode == 404,
        httpResponse.value(forHTTPHeaderField: "Content-Disposition") != nil
      {
        RetroVaultLog.network.error(
          "RomM's file server could not provide game \(gameID, privacy: .public) file \(fileName, privacy: .public)"
        )
        throw RomMAPIError.downloadUnavailable
      }
      _ = try validatedHTTPResponse(httpResponse)
      let resourceValues = try? temporaryFileURL.resourceValues(
        forKeys: [.fileSizeKey]
      )
      let receivedBytes = Int64(
        resourceValues?.fileSize ?? 0
      )
      let expectedBytes = response.expectedContentLength > 0
        ? response.expectedContentLength
        : nil
      onProgress(
        RomMDownloadProgress(
          bytesReceived: receivedBytes,
          totalBytesExpected: expectedBytes
        )
      )
      return RomMDownload(
        temporaryFileURL: temporaryFileURL,
        suggestedFileName: httpResponse.suggestedFilename ?? fileName
      )
    } catch {
      RetroVaultLog.network.error(
        "ROM download failed: \(error.localizedDescription)"
      )
      try? FileManager.default.removeItem(at: temporaryFileURL)
      throw error
    }
  }

  func firmware(
    for platformID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [RomMFirmware] {
    var components = URLComponents(
      url: serverURL.endpoint("api/firmware"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "platform_id", value: String(platformID))
    ]
    guard let url = components?.url else {
      throw RomMAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    authorize(&request, with: token)

    do {
      let data = try await data(for: request)
      return try decoder.decode([FirmwareDTO].self, from: data).map(\.firmware)
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func downloadFirmware(
    _ firmware: RomMFirmware,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    var request = URLRequest(
      url: serverURL.endpoint(
        "api/firmware/\(firmware.id)/content/\(firmware.fileName)"
      )
    )
    authorize(&request, with: token)
    request.setValue(
      "application/octet-stream, */*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    RetroVaultLog.network.debug(
      "GET \(request.url?.path ?? "", privacy: .public) (firmware download)"
    )

    let temporaryFileURL: URL
    let response: URLResponse

    do {
      (temporaryFileURL, response) = try await session.download(for: request)
    } catch let error as URLError {
      guard error.code != .cancelled else {
        throw CancellationError()
      }
      reachability.recordFailure(RomMAPIError.transport(error))
      RetroVaultLog.network.error(
        "Firmware download transport error \(error.code.rawValue, privacy: .public)"
      )
      throw RomMAPIError.transport(error)
    }

    do {
      let httpResponse = try validatedHTTPResponse(response)
      return RomMDownload(
        temporaryFileURL: temporaryFileURL,
        suggestedFileName: httpResponse.suggestedFilename ?? firmware.fileName
      )
    } catch {
      try? FileManager.default.removeItem(at: temporaryFileURL)
      throw error
    }
  }

  func downloadSave(
    _ save: GameSaveDataItem,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    guard
      !save.isMissingFromFileSystem,
      let downloadURL = save.downloadURL,
      serverURL.hasSameOrigin(as: downloadURL)
    else {
      throw RomMAPIError.notFound
    }

    var request = URLRequest(url: downloadURL)
    authorize(&request, with: token)
    request.setValue(
      "application/octet-stream, */*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    RetroVaultLog.network.debug(
      "GET \(request.url?.path ?? "", privacy: .public) (save download)"
    )

    let temporaryFileURL: URL
    let response: URLResponse

    do {
      (temporaryFileURL, response) = try await session.download(for: request)
    } catch let error as URLError {
      guard error.code != .cancelled else {
        throw CancellationError()
      }
      reachability.recordFailure(RomMAPIError.transport(error))
      RetroVaultLog.network.error(
        "Save download transport error \(error.code.rawValue, privacy: .public)"
      )
      throw RomMAPIError.transport(error)
    }

    do {
      let httpResponse = try validatedHTTPResponse(response)
      RetroVaultLog.network.debug(
        "GET \(request.url?.path ?? "", privacy: .public) → \(httpResponse.statusCode, privacy: .public) (save download)"
      )
      return RomMDownload(
        temporaryFileURL: temporaryFileURL,
        suggestedFileName: httpResponse.suggestedFilename ?? save.fileName
      )
    } catch {
      try? FileManager.default.removeItem(at: temporaryFileURL)
      throw error
    }
  }

  func uploadSave(
    _ data: Data,
    fileName: String,
    for gameID: Int,
    emulator: String,
    slot: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameSaveDataItem {
    var components = URLComponents(
      url: serverURL.endpoint("api/saves"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "rom_id", value: String(gameID)),
      URLQueryItem(name: "emulator", value: emulator),
      URLQueryItem(name: "slot", value: slot),
      URLQueryItem(name: "overwrite", value: "false"),
      URLQueryItem(name: "autocleanup", value: "true"),
      URLQueryItem(name: "autocleanup_limit", value: "10"),
    ]
    guard let url = components?.url else {
      throw RomMAPIError.invalidResponse
    }

    let boundary = "RetroVault-\(UUID().uuidString)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    authorize(&request, with: token)
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = multipartBody(
      data: data,
      fieldName: "saveFile",
      fileName: fileName,
      boundary: boundary
    )

    do {
      let responseData = try await self.data(for: request)
      return try decoder.decode(GameSaveDataItemDTO.self, from: responseData)
        .gameSaveDataItem(kind: .save, serverURL: serverURL)
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFiles: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDeletionResult {
    var request = URLRequest(url: serverURL.endpoint("api/roms/delete"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorize(&request, with: token)
    request.httpBody = try encoder.encode(
      DeleteGamesRequestDTO(
        roms: gameIDs,
        deleteFromFileSystem: deletingFiles ? gameIDs : []
      )
    )

    do {
      let data = try await data(for: request)
      let response = try decoder.decode(
        BulkOperationResponseDTO.self,
        from: data
      )
      return GameDeletionResult(
        successfulItemCount: response.successfulItems,
        failedItemCount: response.failedItems,
        errors: response.errors
      )
    } catch let error as RomMAPIError {
      throw error
    } catch {
      throw RomMAPIError.decoding(error)
    }
  }

  private func authenticatedData(at url: URL, token: ClientToken) async throws -> Data {
    var request = URLRequest(url: url)
    authorize(&request, with: token)
    return try await data(for: request)
  }

  private func authorize(_ request: inout URLRequest, with token: ClientToken) {
    request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  private func multipartBody(
    data: Data,
    fieldName: String,
    fileName: String,
    boundary: String
  ) -> Data {
    let safeFileName = URL(fileURLWithPath: fileName)
      .lastPathComponent
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data(
        "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeFileName)\"\r\n"
          .utf8
      )
    )
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  private func data(for request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    let method = request.httpMethod ?? "GET"
    let path = request.url?.path ?? ""

    RetroVaultLog.network.debug(
      "\(method, privacy: .public) \(path, privacy: .public)"
    )
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      guard error.code != .cancelled else {
        throw CancellationError()
      }
      reachability.recordFailure(RomMAPIError.transport(error))
      RetroVaultLog.network.error(
        "\(method, privacy: .public) \(path, privacy: .public) transport error \(error.code.rawValue, privacy: .public)"
      )
      throw RomMAPIError.transport(error)
    }

      reachability.recordServerAnswered()
    guard let response = response as? HTTPURLResponse else {
      RetroVaultLog.network.error(
        "\(method, privacy: .public) \(path, privacy: .public) returned a non-HTTP response"
      )
      throw RomMAPIError.invalidResponse
    }

    RetroVaultLog.network.debug(
      "\(method, privacy: .public) \(path, privacy: .public) → \(response.statusCode, privacy: .public)"
    )
    _ = try validatedHTTPResponse(response)
    return data
  }

  private func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    reachability.recordServerAnswered()
    guard let response = response as? HTTPURLResponse else {
      throw RomMAPIError.invalidResponse
    }

    switch response.statusCode {
    case 200..<300:
      return response
    case 401:
      throw RomMAPIError.unauthorized
    case 403:
      throw RomMAPIError.forbidden
    case 404:
      throw RomMAPIError.notFound
    default:
      throw RomMAPIError.server(statusCode: response.statusCode)
    }
  }
}

private struct PairingCodeDTO: Encodable {
  let code: String
}

private struct ClientTokenDTO: Decodable {
  let rawToken: String

  enum CodingKeys: String, CodingKey {
    case rawToken = "raw_token"
  }
}

private struct UserDTO: Decodable {
  let id: Int
  let username: String
  let oauthScopes: [String]

  enum CodingKeys: String, CodingKey {
    case id
    case username
    case oauthScopes = "oauth_scopes"
  }
}

private struct DeleteGamesRequestDTO: Encodable {
  let roms: [Int]
  let deleteFromFileSystem: [Int]

  enum CodingKeys: String, CodingKey {
    case roms
    case deleteFromFileSystem = "delete_from_fs"
  }
}

private struct BulkOperationResponseDTO: Decodable {
  let successfulItems: Int
  let failedItems: Int
  let errors: [String]

  enum CodingKeys: String, CodingKey {
    case successfulItems = "successful_items"
    case failedItems = "failed_items"
    case errors
  }
}

private struct SystemDTO: Decodable {
  let id: Int
  let displayName: String
  let gameCount: Int

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case gameCount = "rom_count"
  }
}

private struct CollectionDTO: Decodable {
  let id: Int
  let name: String
  let gameCount: Int
  let isFavorite: Bool?
  let gameIDs: [Int]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case gameCount = "rom_count"
    case isFavorite = "is_favorite"
    case gameIDs = "rom_ids"
  }
}

private struct CollectionRomsRequestDTO: Encodable {
  let romIDs: [Int]

  enum CodingKeys: String, CodingKey {
    case romIDs = "rom_ids"
  }
}

private struct GamePageDTO: Decodable {
  let items: [GameDTO]
  let total: Int
  let limit: Int
  let offset: Int
}

private struct GameDTO: Decodable {
  let id: Int
  let systemID: Int
  let systemName: String
  let fileNameWithoutExtension: String
  let name: String?
  let smallCoverPath: String?
  let largeCoverPath: String?
  let remoteCoverURL: String?
  let userMetadata: GameUserMetadataDTO?
  let metadata: GameMetadataDTO?
  let regions: [String]?
  let fileSizeBytes: Int64?
  let isIdentified: Bool?
  let isMissingFromFileSystem: Bool?
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case systemID = "platform_id"
    case systemName = "platform_display_name"
    case fileNameWithoutExtension = "fs_name_no_ext"
    case name
    case smallCoverPath = "path_cover_small"
    case largeCoverPath = "path_cover_large"
    case remoteCoverURL = "url_cover"
    case userMetadata = "rom_user"
    case metadata = "metadatum"
    case regions
    case fileSizeBytes = "fs_size_bytes"
    case isIdentified = "is_identified"
    case isMissingFromFileSystem = "missing_from_fs"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  func gameSummary(serverURL: ServerURL) -> GameSummary {
    let metadataName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = metadataName.flatMap { $0.isEmpty ? nil : $0 } ?? fileNameWithoutExtension
    let coverPath = [smallCoverPath, largeCoverPath, remoteCoverURL]
      .compactMap { $0 }
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    return GameSummary(
      id: id,
      name: displayName,
      systemID: systemID,
      systemName: systemName,
      coverURL: serverURL.resourceURL(for: coverPath),
      isBIOS: hasBIOSPrefix,
      userStatus: userMetadata?.status,
      completion: userMetadata?.completion,
      rating: userMetadata?.rating,
      difficulty: userMetadata?.difficulty,
      genres: metadata?.genres,
      releaseYear: releaseYear,
      regions: regions,
      fileSizeBytes: fileSizeBytes,
      isIdentified: isIdentified,
      isMissingFromFileSystem: isMissingFromFileSystem,
      createdAt: createdAt,
      updatedAt: updatedAt,
      serverLastPlayed: userMetadata?.lastPlayed
    )
  }

  private var hasBIOSPrefix: Bool {
    [name, fileNameWithoutExtension]
      .compactMap { $0 }
      .contains { candidate in
        candidate
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .uppercased()
          .hasPrefix("[BIOS]")
      }
  }

  private var releaseYear: Int? {
    guard let releaseDate = metadata?.gameMetadata.firstReleaseDate else {
      return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    return calendar.component(.year, from: releaseDate)
  }
}

private struct GameDetailsDTO: Decodable {
  let id: Int
  let systemID: Int?
  let systemName: String?
  let fileName: String?
  let fileNameWithoutExtension: String?
  let fileExtension: String?
  let filePath: String?
  let fileSizeBytes: Int64?
  let fullPath: String?
  let name: String?
  let summary: String?
  let alternativeNames: [String]?
  let metadata: GameMetadataDTO?
  let smallCoverPath: String?
  let largeCoverPath: String?
  let remoteCoverURL: String?
  let screenshotPaths: [String]?
  let hasManual: Bool?
  let hasSoundtrack: Bool?
  let manualPath: String?
  let remoteManualURL: String?
  let videoPath: String?
  let isIdentified: Bool?
  let isMissingFromFileSystem: Bool?
  let revision: String?
  let regions: [String]?
  let languages: [String]?
  let tags: [String]?
  let crcHash: String?
  let md5Hash: String?
  let sha1Hash: String?
  let retroAchievementsHash: String?
  let createdAt: String?
  let updatedAt: String?
  let files: [GameFileDTO]?
  let userMetadata: GameUserMetadataDTO?
  let siblingGames: [DiscardedDTO]?
  let userSaves: [GameSaveDataItemDTO]?
  let userStates: [GameSaveDataItemDTO]?
  let userScreenshots: [DiscardedDTO]?
  let userCollections: [DiscardedDTO]?
  let userNotes: [DiscardedDTO]?
  let igdbID: Int?
  let steamGridDBID: Int?
  let mobyGamesID: Int?
  let screenScraperID: Int?
  let retroAchievementsID: Int?
  let launchBoxID: Int?
  let hasheousID: Int?
  let gamesDBID: Int?
  let flashpointID: String?
  let howLongToBeatID: Int?
  let gameListID: String?
  let libretroID: String?

  enum CodingKeys: String, CodingKey {
    case id
    case systemID = "platform_id"
    case systemName = "platform_display_name"
    case fileName = "fs_name"
    case fileNameWithoutExtension = "fs_name_no_ext"
    case fileExtension = "fs_extension"
    case filePath = "fs_path"
    case fileSizeBytes = "fs_size_bytes"
    case fullPath = "full_path"
    case name
    case summary
    case alternativeNames = "alternative_names"
    case metadata = "metadatum"
    case smallCoverPath = "path_cover_small"
    case largeCoverPath = "path_cover_large"
    case remoteCoverURL = "url_cover"
    case screenshotPaths = "merged_screenshots"
    case hasManual = "has_manual"
    case hasSoundtrack = "has_soundtrack"
    case manualPath = "path_manual"
    case remoteManualURL = "url_manual"
    case videoPath = "path_video"
    case isIdentified = "is_identified"
    case isMissingFromFileSystem = "missing_from_fs"
    case revision
    case regions
    case languages
    case tags
    case crcHash = "crc_hash"
    case md5Hash = "md5_hash"
    case sha1Hash = "sha1_hash"
    case retroAchievementsHash = "ra_hash"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case files
    case userMetadata = "rom_user"
    case siblingGames = "sibling_roms"
    case userSaves = "user_saves"
    case userStates = "user_states"
    case userScreenshots = "user_screenshots"
    case userCollections = "user_collections"
    case userNotes = "all_user_notes"
    case igdbID = "igdb_id"
    case steamGridDBID = "sgdb_id"
    case mobyGamesID = "moby_id"
    case screenScraperID = "ss_id"
    case retroAchievementsID = "ra_id"
    case launchBoxID = "launchbox_id"
    case hasheousID = "hasheous_id"
    case gamesDBID = "tgdb_id"
    case flashpointID = "flashpoint_id"
    case howLongToBeatID = "hltb_id"
    case gameListID = "gamelist_id"
    case libretroID = "libretro_id"
  }

  func gameDetails(serverURL: ServerURL) -> GameDetails {
    let displayName =
      Self.nonempty(name)
      ?? Self.nonempty(fileNameWithoutExtension)
      ?? Self.nonempty(fileName)
      ?? "Untitled Game"
    let coverPath = [largeCoverPath, smallCoverPath, remoteCoverURL]
      .compactMap { Self.nonempty($0) }
      .first

    return GameDetails(
      id: id,
      name: displayName,
      systemID: systemID ?? 0,
      systemName: Self.nonempty(systemName) ?? "Unknown System",
      summary: Self.nonempty(summary),
      coverURL: serverURL.resourceURL(for: coverPath),
      screenshotURLs: (screenshotPaths ?? []).compactMap(serverURL.resourceURL(for:)),
      alternativeNames: alternativeNames ?? [],
      metadata: metadata?.gameMetadata
        ?? GameMetadata(
          genres: [],
          franchises: [],
          collections: [],
          companies: [],
          gameModes: [],
          ageRatings: [],
          playerCount: nil,
          firstReleaseDate: nil,
          averageRating: nil
        ),
      regions: regions ?? [],
      languages: languages ?? [],
      tags: tags ?? [],
      files: (files ?? []).map(\.gameFile),
      fileName: Self.nonempty(fileName) ?? displayName,
      fileExtension: Self.nonempty(fileExtension) ?? "",
      filePath: Self.nonempty(filePath) ?? "",
      fullPath: Self.nonempty(fullPath) ?? "",
      fileSizeBytes: fileSizeBytes ?? 0,
      revision: Self.nonempty(revision),
      crcHash: Self.nonempty(crcHash),
      md5Hash: Self.nonempty(md5Hash),
      sha1Hash: Self.nonempty(sha1Hash),
      retroAchievementsHash: Self.nonempty(retroAchievementsHash),
      isIdentified: isIdentified ?? false,
      isMissingFromFileSystem: isMissingFromFileSystem ?? false,
      hasManual: hasManual ?? false,
      hasSoundtrack: hasSoundtrack ?? false,
      manualURL: serverURL.resourceURL(
        for: Self.nonempty(manualPath) ?? Self.nonempty(remoteManualURL)),
      videoURL: serverURL.resourceURL(for: Self.nonempty(videoPath)),
      createdAt: createdAt ?? "",
      updatedAt: updatedAt ?? "",
      userMetadata: userMetadata?.gameUserMetadata
        ?? GameUserMetadata(
          status: nil,
          lastPlayed: nil,
          rating: 0,
          difficulty: 0,
          completion: 0,
          isBacklogged: false,
          isNowPlaying: false,
          isHidden: false
        ),
      saves: (userSaves ?? []).map {
        $0.gameSaveDataItem(kind: .save, serverURL: serverURL)
      },
      states: (userStates ?? []).map {
        $0.gameSaveDataItem(kind: .state, serverURL: serverURL)
      },
      contentCounts: GameContentCounts(
        siblingGames: siblingGames?.count ?? 0,
        saves: userSaves?.count ?? 0,
        states: userStates?.count ?? 0,
        screenshots: userScreenshots?.count ?? 0,
        collections: userCollections?.count ?? 0,
        notes: userNotes?.count ?? 0
      ),
      providerIdentifiers: providerIdentifiers
    )
  }

  private var providerIdentifiers: [GameProviderIdentifier] {
    var identifiers: [GameProviderIdentifier] = []

    func append(_ name: String, _ value: String?) {
      if let value = Self.nonempty(value) {
        identifiers.append(GameProviderIdentifier(name: name, value: value))
      }
    }

    append("IGDB", igdbID.map(String.init))
    append("SteamGridDB", steamGridDBID.map(String.init))
    append("MobyGames", mobyGamesID.map(String.init))
    append("ScreenScraper", screenScraperID.map(String.init))
    append("RetroAchievements", retroAchievementsID.map(String.init))
    append("LaunchBox", launchBoxID.map(String.init))
    append("Hasheous", hasheousID.map(String.init))
    append("TheGamesDB", gamesDBID.map(String.init))
    append("Flashpoint", flashpointID)
    append("HowLongToBeat", howLongToBeatID.map(String.init))
    append("GameList", gameListID)
    append("Libretro", libretroID)

    return identifiers
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct GameMetadataDTO: Decodable {
  let genres: [String]?
  let franchises: [String]?
  let collections: [String]?
  let companies: [String]?
  let gameModes: [String]?
  let ageRatings: [String]?
  let playerCount: String?
  let firstReleaseDate: Int64?
  let averageRating: Double?

  enum CodingKeys: String, CodingKey {
    case genres
    case franchises
    case collections
    case companies
    case gameModes = "game_modes"
    case ageRatings = "age_ratings"
    case playerCount = "player_count"
    case firstReleaseDate = "first_release_date"
    case averageRating = "average_rating"
  }

  var gameMetadata: GameMetadata {
    GameMetadata(
      genres: genres ?? [],
      franchises: franchises ?? [],
      collections: collections ?? [],
      companies: companies ?? [],
      gameModes: gameModes ?? [],
      ageRatings: ageRatings ?? [],
      playerCount: playerCount,
      firstReleaseDate: firstReleaseDate.map { rawValue in
        let divisor = rawValue > 10_000_000_000 ? 1_000.0 : 1.0
        return Date(timeIntervalSince1970: Double(rawValue) / divisor)
      },
      averageRating: averageRating
    )
  }
}

private struct GameFileDTO: Decodable {
  let id: Int
  let name: String?
  let path: String?
  let fullPath: String?
  let sizeBytes: Int64?
  let category: String?
  let isTopLevel: Bool?
  let createdAt: String?
  let updatedAt: String?
  let lastModified: String?
  let crcHash: String?
  let md5Hash: String?
  let sha1Hash: String?
  let retroAchievementsHash: String?
  let chdSHA1Hash: String?
  let archiveMembers: [GameArchiveMemberDTO]?
  let trackMetadata: GameTrackMetadataDTO?

  enum CodingKeys: String, CodingKey {
    case id
    case name = "file_name"
    case path = "file_path"
    case fullPath = "full_path"
    case sizeBytes = "file_size_bytes"
    case category
    case isTopLevel = "is_top_level"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case lastModified = "last_modified"
    case crcHash = "crc_hash"
    case md5Hash = "md5_hash"
    case sha1Hash = "sha1_hash"
    case retroAchievementsHash = "ra_hash"
    case chdSHA1Hash = "chd_sha1_hash"
    case archiveMembers = "archive_members"
    case trackMetadata = "track_meta"
  }

  var gameFile: GameFile {
    GameFile(
      id: id,
      name: name ?? "Untitled File",
      path: path ?? "",
      fullPath: fullPath ?? "",
      sizeBytes: sizeBytes ?? 0,
      category: category,
      isTopLevel: isTopLevel ?? false,
      createdAt: createdAt ?? "",
      updatedAt: updatedAt ?? "",
      lastModified: lastModified ?? "",
      crcHash: crcHash,
      md5Hash: md5Hash,
      sha1Hash: sha1Hash,
      retroAchievementsHash: retroAchievementsHash,
      chdSHA1Hash: chdSHA1Hash,
      archiveMembers: (archiveMembers ?? []).map(\.gameArchiveMember),
      trackMetadata: trackMetadata?.gameTrackMetadata
    )
  }
}

private struct GameArchiveMemberDTO: Decodable {
  let name: String
  let sizeBytes: Int64
  let crcHash: String
  let md5Hash: String
  let sha1Hash: String

  enum CodingKeys: String, CodingKey {
    case name
    case sizeBytes = "size"
    case crcHash = "crc_hash"
    case md5Hash = "md5_hash"
    case sha1Hash = "sha1_hash"
  }

  var gameArchiveMember: GameArchiveMember {
    GameArchiveMember(
      name: name,
      sizeBytes: sizeBytes,
      crcHash: crcHash,
      md5Hash: md5Hash,
      sha1Hash: sha1Hash
    )
  }
}

private struct GameTrackMetadataDTO: Decodable {
  let title: String?
  let artist: String?
  let album: String?
  let year: Int?
  let genre: String?
  let track: Int?
  let disc: Int?
  let durationSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case title
    case artist
    case album
    case year
    case genre
    case track
    case disc
    case durationSeconds = "duration_seconds"
  }

  var gameTrackMetadata: GameTrackMetadata {
    GameTrackMetadata(
      title: title,
      artist: artist,
      album: album,
      year: year,
      genre: genre,
      track: track,
      disc: disc,
      durationSeconds: durationSeconds
    )
  }
}

private struct GameUserMetadataDTO: Decodable {
  let status: String?
  let lastPlayed: String?
  let rating: Int?
  let difficulty: Int?
  let completion: Int?
  let isBacklogged: Bool?
  let isNowPlaying: Bool?
  let isHidden: Bool?

  enum CodingKeys: String, CodingKey {
    case status
    case lastPlayed = "last_played"
    case rating
    case difficulty
    case completion
    case isBacklogged = "backlogged"
    case isNowPlaying = "now_playing"
    case isHidden = "hidden"
  }

  var gameUserMetadata: GameUserMetadata {
    GameUserMetadata(
      status: status,
      lastPlayed: lastPlayed,
      rating: rating ?? 0,
      difficulty: difficulty ?? 0,
      completion: completion ?? 0,
      isBacklogged: isBacklogged ?? false,
      isNowPlaying: isNowPlaying ?? false,
      isHidden: isHidden ?? false
    )
  }
}

private struct GameUserMetadataUpdateDTO: Encodable {
  let status: String?
  let rating: Int
  let difficulty: Int
  let completion: Int
  let isBacklogged: Bool
  let isNowPlaying: Bool
  let isHidden: Bool

  init(metadata: GameUserMetadata) {
    status = metadata.status
    rating = metadata.rating
    difficulty = metadata.difficulty
    completion = metadata.completion
    isBacklogged = metadata.isBacklogged
    isNowPlaying = metadata.isNowPlaying
    isHidden = metadata.isHidden
  }

  enum CodingKeys: String, CodingKey {
    case status
    case rating
    case difficulty
    case completion
    case isBacklogged = "backlogged"
    case isNowPlaying = "now_playing"
    case isHidden = "hidden"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let status {
      try container.encode(status, forKey: .status)
    } else {
      try container.encodeNil(forKey: .status)
    }
    try container.encode(rating, forKey: .rating)
    try container.encode(difficulty, forKey: .difficulty)
    try container.encode(completion, forKey: .completion)
    try container.encode(isBacklogged, forKey: .isBacklogged)
    try container.encode(isNowPlaying, forKey: .isNowPlaying)
    try container.encode(isHidden, forKey: .isHidden)
  }
}

private struct FirmwareDTO: Decodable {
  let id: Int
  let fileName: String
  let fileSizeBytes: Int64
  let sha1Hash: String?
  let isVerified: Bool
  let isMissingFromFileSystem: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case fileName = "file_name"
    case fileSizeBytes = "file_size_bytes"
    case sha1Hash = "sha1_hash"
    case isVerified = "is_verified"
    case isMissingFromFileSystem = "missing_from_fs"
  }

  var firmware: RomMFirmware {
    RomMFirmware(
      id: id,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      sha1Hash: sha1Hash,
      isVerified: isVerified,
      isMissingFromFileSystem: isMissingFromFileSystem
    )
  }
}

private struct GameSaveDataItemDTO: Decodable {
  let id: Int
  let fileName: String
  let fileExtension: String
  let filePath: String
  let fullPath: String
  let downloadPath: String
  let fileSizeBytes: Int64
  let isMissingFromFileSystem: Bool
  let createdAt: String
  let updatedAt: String
  let emulator: String?
  let slot: String?
  let contentHash: String?
  let isPublic: Bool?
  let screenshot: GameSaveScreenshotDTO?

  enum CodingKeys: String, CodingKey {
    case id
    case fileName = "file_name"
    case fileExtension = "file_extension"
    case filePath = "file_path"
    case fullPath = "full_path"
    case downloadPath = "download_path"
    case fileSizeBytes = "file_size_bytes"
    case isMissingFromFileSystem = "missing_from_fs"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case emulator
    case slot
    case contentHash = "content_hash"
    case isPublic = "is_public"
    case screenshot
  }

  func gameSaveDataItem(
    kind: GameSaveDataItem.Kind,
    serverURL: ServerURL
  ) -> GameSaveDataItem {
    GameSaveDataItem(
      id: id,
      kind: kind,
      fileName: fileName,
      fileExtension: fileExtension,
      filePath: filePath,
      fullPath: fullPath,
      downloadURL: serverURL.resourceURL(for: downloadPath),
      fileSizeBytes: fileSizeBytes,
      isMissingFromFileSystem: isMissingFromFileSystem,
      createdAt: parseISO8601Date(createdAt),
      updatedAt: parseISO8601Date(updatedAt),
      emulator: emulator,
      slot: slot,
      contentHash: contentHash,
      isPublic: isPublic ?? false,
      screenshotURL: serverURL.resourceURL(for: screenshot?.downloadPath)
    )
  }
}

private struct GameSaveScreenshotDTO: Decodable {
  let downloadPath: String

  enum CodingKeys: String, CodingKey {
    case downloadPath = "download_path"
  }
}

private struct DiscardedDTO: Decodable {}

private func parseISO8601Date(_ value: String) -> Date? {
  try? Date(value, strategy: .iso8601)
}
