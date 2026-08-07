import Foundation

/// Reassembles the plist stream produced by `powermetrics`.
///
/// Apple documents plist output as NUL-separated, but current macOS releases
/// can place that separator before each complete XML document. Waiting for the
/// *next* separator needlessly delays the first usable sample and can race the
/// startup watchdog. A complete XML closing tag is therefore also accepted as
/// a frame boundary, while NUL framing remains as a compatibility fallback.
nonisolated struct PowerMetricsFrameDecoder: Sendable {
    private static let xmlDocumentEnd = Data("</plist>".utf8)

    private var buffer = Data()

    var bufferedByteCount: Int {
        buffer.count
    }

    /// Returns `nil` and clears buffered input when either an incomplete frame
    /// or one completed frame exceeds `maximumFrameBytes`.
    mutating func append(
        _ data: Data,
        maximumFrameBytes: Int = .max
    ) -> [Data]? {
        guard !data.isEmpty else { return [] }

        buffer.append(data)
        var frames: [Data] = []
        let byteLimit = max(0, maximumFrameBytes)

        while true {
            trimFrameSeparators()
            guard !buffer.isEmpty else { break }

            let delimiter = buffer.firstIndex(of: 0)
            let xmlEnd = buffer.range(of: Self.xmlDocumentEnd)

            if let delimiter,
               xmlEnd == nil || delimiter < xmlEnd!.lowerBound {
                let frameByteCount = buffer.distance(
                    from: buffer.startIndex,
                    to: delimiter
                )
                guard frameByteCount <= byteLimit else {
                    reset(keepingCapacity: false)
                    return nil
                }
                let frame = Data(buffer[..<delimiter])
                buffer.removeSubrange(...delimiter)
                if frame.contains(where: { !Self.isInterFrameByte($0) }) {
                    frames.append(frame)
                }
                continue
            }

            if let xmlEnd {
                let frameEnd = xmlEnd.upperBound
                let frameByteCount = buffer.distance(
                    from: buffer.startIndex,
                    to: frameEnd
                )
                guard frameByteCount <= byteLimit else {
                    reset(keepingCapacity: false)
                    return nil
                }
                frames.append(Data(buffer[..<frameEnd]))
                buffer.removeSubrange(..<frameEnd)
                continue
            }

            break
        }

        guard buffer.count <= byteLimit else {
            reset(keepingCapacity: false)
            return nil
        }

        return frames
    }

    mutating func reset(keepingCapacity: Bool) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    private mutating func trimFrameSeparators() {
        let contentStart = buffer.firstIndex {
            !Self.isInterFrameByte($0)
        } ?? buffer.endIndex
        if contentStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<contentStart)
        }
    }

    private static func isInterFrameByte(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}
