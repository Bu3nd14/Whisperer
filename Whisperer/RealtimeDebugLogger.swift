import Foundation

enum RealtimeDebugLogger {
    static let fileName = "whisperer-realtime.jsonl"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func reset() {
        try? Data().write(to: fileURL, options: .atomic)
        write(direction: "app", event: [
            "type": "log.started",
            "device_time": ISO8601DateFormatter().string(from: Date())
        ])
    }

    static func logOutgoing(_ event: [String: Any]) {
        guard !(event["type"] as? String ?? "").hasSuffix("input_audio_buffer.append") else { return }
        write(direction: "client", event: event)
    }

    static func logAudioProgress(
        seconds: Double,
        inputLevel: Double,
        transmittedLevel: Double,
        clippingRatio: Double
    ) {
        write(direction: "client", event: [
            "type": "audio.progress",
            "seconds": Int(seconds),
            "level": inputLevel,
            "transmitted_level": transmittedLevel,
            "clipping_ratio": clippingRatio
        ])
    }

    static func logIncoming(_ event: [String: Any]) {
        var sanitized = event
        if event["type"] as? String == "session.output_audio.delta",
           let delta = event["delta"] as? String {
            sanitized["delta"] = "<audio omitted: \(delta.count) base64 characters>"
        }
        write(direction: "server", event: sanitized)
    }

    private static func write(direction: String, event: [String: Any]) {
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "direction": direction,
            "event": event
        ]
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return
        }
        data.append(0x0A)

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
