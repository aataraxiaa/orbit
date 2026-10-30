import Foundation

/// Orbit's stable identifiers compare code points, never Unicode normalization.
public struct OrbitByteString: Hashable, Comparable, Sendable {
  public let value: String
  public init(_ value: String) { self.value = value }
  public static func == (_ lhs: Self, _ rhs: Self) -> Bool {
    lhs.value.utf8.elementsEqual(rhs.value.utf8)
  }
  public func hash(into hasher: inout Hasher) { for byte in value.utf8 { hasher.combine(byte) } }
  public static func < (_ lhs: Self, _ rhs: Self) -> Bool {
    lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
  }
}
public typealias NoteIdentityTable = [OrbitByteString: Set<String>]
