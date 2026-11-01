import Foundation

public struct OrbitRetrievalRequest: Sendable {
  public let query: String
  public let path: String?
  public let scope: String?
  public let limit: Int
  public let maximumEvidenceBytes: Int

  public init(query: String, path: String? = nil, scope: String? = nil,
              limit: Int = 3, maximumEvidenceBytes: Int = 6_000) {
    self.query = query
    self.path = path
    self.scope = scope
    self.limit = max(1, min(limit, 100))
    self.maximumEvidenceBytes = max(512, min(maximumEvidenceBytes, 64_000))
  }
}

public enum OrbitRetrievalAvailability: Sendable {
  case ready(OrbitRetrievalSnapshot.Result, refreshing: Bool, refreshError: String?)
  case preparing
  case unavailable(String)
}

/// A host supplies authorized capture; queries read only retained device-local evidence.
public actor OrbitRetrievalService {
  private let orbitID: String
  private let archiveURL: URL
  private var snapshot: OrbitRetrievalSnapshot?
  private var loadTask: Task<OrbitRetrievalSnapshot, Error>?
  private var refreshTask: Task<Void, Error>?
  private var refreshID: UUID?
  private var lastError: String?
  private var attemptedLoad = false
  private var active = true
  private var epoch = 0

  public init(orbitID: String, sourceBinding: String, localDirectory: URL) throws {
    guard UUID(uuidString: orbitID) != nil, !sourceBinding.isEmpty else {
      throw OrbitError("Retrieval requires a bound Orbit identity")
    }
    self.orbitID = orbitID
    let key = digest(Data((orbitID + "\0" + sourceBinding).utf8))
    self.archiveURL = localDirectory.appendingPathComponent(key + ".json")
  }

  public func retrieve(_ request: OrbitRetrievalRequest) async throws -> OrbitRetrievalAvailability {
    guard active else { return .unavailable("This Orbit is disconnected") }
    if snapshot == nil && (loadTask != nil || !attemptedLoad) {
      let generation = epoch
      let task: Task<OrbitRetrievalSnapshot, Error>
      if let pending = loadTask { task = pending }
      else {
        attemptedLoad = true
        let url = archiveURL, expectedID = orbitID
        task = Task.detached {
          try autoreleasepool { try OrbitRetrievalSnapshot(contentsOf: url, expectedOrbitID: expectedID) }
        }
        loadTask = task
      }
      do {
        let loaded = try await task.value
        guard active, epoch == generation else { return .unavailable("This Orbit is disconnected") }
        if snapshot == nil { snapshot = loaded }
      } catch is CancellationError { throw CancellationError() }
      catch { if snapshot == nil { lastError = "No retained evidence is available yet" } }
      loadTask = nil
    }
    guard active else { return .unavailable("This Orbit is disconnected") }
    guard let snapshot else {
      return refreshTask == nil ? .unavailable(lastError ?? "Prepare this Orbit before searching") : .preparing
    }
    return .ready(try autoreleasepool { try snapshot.retrieve(query: request.query, limit: request.limit,
      scope: request.scope, path: request.path, maximumBytes: request.maximumEvidenceBytes) },
      refreshing: refreshTask != nil, refreshError: lastError)
  }

  /// Capture may await provider work. Existing evidence remains queryable throughout it.
  public func refresh(using capture: @escaping @Sendable () async throws -> OrbitRetrievalSnapshot) async throws {
    guard active else { throw OrbitError("This Orbit is disconnected") }
    let task: Task<Void, Error>
    let token: UUID
    if let pending = refreshTask, let pendingID = refreshID {
      task = pending
      token = pendingID
    } else {
      token = UUID()
      let generation = epoch
      lastError = nil
      task = Task {
        let captured = try await capture()
        try Task.checkCancellation()
        try self.publish(captured, generation: generation)
      }
      refreshTask = task
      refreshID = token
    }
    do {
      try await task.value
      if refreshID == token { refreshTask = nil; refreshID = nil; lastError = nil }
    } catch {
      if refreshID == token { refreshTask = nil; refreshID = nil; lastError = String(describing: error) }
      throw error
    }
  }

  private func publish(_ captured: OrbitRetrievalSnapshot, generation: Int) throws {
    guard active, generation == epoch, captured.orbitID == orbitID else {
      throw OrbitError("Retrieval binding changed during refresh")
    }
    try autoreleasepool {
      try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try captured.write(to: archiveURL)
    }
    snapshot = captured
    attemptedLoad = true
  }

  public func invalidate() throws {
    active = false
    epoch += 1
    loadTask?.cancel()
    refreshTask?.cancel()
    snapshot = nil
    if FileManager.default.fileExists(atPath: archiveURL.path) {
      try FileManager.default.removeItem(at: archiveURL)
    }
  }
}
