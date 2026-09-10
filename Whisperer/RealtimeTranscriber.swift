@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class RealtimeTranscriber: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var transcript = ""
    @Published private(set) var partialTranscript = ""
    @Published private(set) var sourceTranscript = ""
    @Published private(set) var status = "Pronto"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAPIConnected = false
    @Published private(set) var audioSecondsSent = 0.0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var hasReceivedTranslation = false
    @Published private(set) var pendingTranslations = 0

    private let audioEngine = AVAudioEngine()
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var stopFallbackTask: Task<Void, Never>?
    private var translationTasks: [Int: Task<Void, Never>] = [:]
    private var completedTranslations: [Int: String] = [:]
    private var nextTranslationID = 0
    private var nextTranslationToDisplay = 0
    private var lastLoggedAudioSecond = 0
    private var clippedSamplesSinceLastLog = 0
    private var samplesSinceLastLog = 0
    private var hasDetectedSpeech = false
    private var bufferedAudioDuration = 0.0
    private var silenceDuration = 0.0
    private var apiKey = ""

    var debugLogName: String { RealtimeDebugLogger.fileName }

    var displayedTranscript: String {
        transcript
    }

    var displayedSourceTranscript: String {
        [sourceTranscript, partialTranscript]
            .filter { !$0.isEmpty }
            .joined(separator: sourceTranscript.isEmpty ? "" : " ")
    }

    func start(apiKey: String) async {
        guard !isRecording, !isBusy else { return }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Inserisci prima una chiave API OpenAI."
            return
        }

        isBusy = true
        self.apiKey = key
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
        completedTranslations.removeAll()
        nextTranslationID = 0
        nextTranslationToDisplay = 0
        pendingTranslations = 0
        isAPIConnected = false
        audioSecondsSent = 0
        microphoneLevel = 0
        hasReceivedTranslation = false
        lastLoggedAudioSecond = 0
        clippedSamplesSinceLastLog = 0
        samplesSinceLastLog = 0
        hasDetectedSpeech = false
        bufferedAudioDuration = 0
        silenceDuration = 0
        errorMessage = nil
        status = "Richiesta accesso al microfono..."
        RealtimeDebugLogger.reset()

        guard await AVAudioApplication.requestRecordPermission() else {
            isBusy = false
            status = "Microfono non autorizzato"
            errorMessage = "Abilita il microfono in Impostazioni > Privacy e sicurezza > Microfono."
            return
        }

        do {
            try configureAudioSession()
            try connect(apiKey: key)
            status = "Configurazione traduzione..."
        } catch {
            stopImmediately()
            isBusy = false
            status = "Errore"
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRecording else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false
        isBusy = true
        status = "Finalizzazione..."
        if hasDetectedSpeech {
            send(event: ["type": "input_audio_buffer.commit"])
            hasDetectedSpeech = false
        } else {
            finishSession()
            return
        }

        stopFallbackTask?.cancel()
        stopFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finishSession()
        }
    }

    func clearTranscript() {
        transcript = ""
        partialTranscript = ""
        sourceTranscript = ""
    }

    func dismissError() {
        errorMessage = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func connect(apiKey: String) throws {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw TranscriberError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let socket = URLSession.shared.webSocketTask(with: request)
        webSocket = socket
        socket.resume()
        receiveMessages(from: socket)

        send(event: [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "noise_reduction": ["type": "far_field"],
                        "transcription": [
                            "model": "gpt-transcribe"
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ])
    }

    private func startAudioCapture() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriberError.unsupportedAudioFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { [weak self] buffer, _ in
            guard let data = Self.convert(buffer, with: converter, outputFormat: outputFormat) else { return }
            Task { @MainActor [weak self] in
                self?.handleAudioChunk(data)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    nonisolated private static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        let audioBuffer = output.audioBufferList.pointee.mBuffers
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard conversionError == nil,
              status != .error,
              byteCount > 0,
              byteCount <= Int(audioBuffer.mDataByteSize),
              let bytes = audioBuffer.mData else {
            return nil
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func handleAudioChunk(_ data: Data) {
        let rawRMS = Self.rootMeanSquare(of: data)
        let gainedAudio = Self.applyGain(to: data, multiplier: 5)
        let transmittedRMS = Self.rootMeanSquare(of: gainedAudio.data)
        let transmittedLevel = min(transmittedRMS * 10, 1)
        let duration = Double(gainedAudio.data.count) / 48_000
        audioSecondsSent += duration
        microphoneLevel = transmittedLevel
        clippedSamplesSinceLastLog += gainedAudio.clippedSamples
        samplesSinceLastLog += data.count / MemoryLayout<Int16>.size
        let elapsedSecond = Int(audioSecondsSent)
        if elapsedSecond > lastLoggedAudioSecond {
            lastLoggedAudioSecond = elapsedSecond
            let clippingRatio = samplesSinceLastLog > 0
                ? Double(clippedSamplesSinceLastLog) / Double(samplesSinceLastLog)
                : 0
            RealtimeDebugLogger.logAudioProgress(
                seconds: audioSecondsSent,
                inputLevel: min(rawRMS * 10, 1),
                transmittedLevel: transmittedLevel,
                clippingRatio: clippingRatio
            )
            clippedSamplesSinceLastLog = 0
            samplesSinceLastLog = 0
        }
        send(event: [
            "type": "input_audio_buffer.append",
            "audio": gainedAudio.data.base64EncodedString()
        ])
        bufferedAudioDuration += duration

        let speechThreshold = hasDetectedSpeech ? 0.002 : 0.004
        if transmittedRMS > speechThreshold {
            hasDetectedSpeech = true
            silenceDuration = 0
        } else if hasDetectedSpeech {
            silenceDuration += duration
            if silenceDuration >= 0.6 {
                send(event: ["type": "input_audio_buffer.commit"])
                hasDetectedSpeech = false
                bufferedAudioDuration = 0
                silenceDuration = 0
            }
        }
        if hasDetectedSpeech && bufferedAudioDuration >= 6 {
            send(event: ["type": "input_audio_buffer.commit"])
            hasDetectedSpeech = false
            bufferedAudioDuration = 0
            silenceDuration = 0
        } else if !hasDetectedSpeech && bufferedAudioDuration >= 2 {
            send(event: ["type": "input_audio_buffer.clear"])
            bufferedAudioDuration = 0
        }
    }

    nonisolated private static func applyGain(
        to data: Data,
        multiplier: Int
    ) -> (data: Data, clippedSamples: Int) {
        var output = data
        var clippedSamples = 0
        output.withUnsafeMutableBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for index in samples.indices {
                let amplified = Int(Int16(littleEndian: samples[index])) * multiplier
                if amplified < Int(Int16.min) || amplified > Int(Int16.max) {
                    clippedSamples += 1
                }
                samples[index] = Int16(clamping: amplified).littleEndian
            }
        }
        return (output, clippedSamples)
    }

    nonisolated private static func rootMeanSquare(of data: Data) -> Double {
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(into: 0.0) { result, sample in
                let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
                result += normalized * normalized
            }
            return sqrt(sum / Double(samples.count))
        }
    }

    private func send(event: [String: Any]) {
        guard let webSocket,
              JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }

        RealtimeDebugLogger.logOutgoing(event)

        let previousSend = sendTask
        sendTask = Task { [weak self] in
            _ = await previousSend?.result
            guard !Task.isCancelled else { return }
            do {
                try await webSocket.send(.string(text))
            } catch {
                self?.handleFailure(error)
            }
        }
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    self?.handleServerEvent(data)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleFailure(error)
                    return
                }
            }
        }
    }

    private func handleServerEvent(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        RealtimeDebugLogger.logIncoming(event)

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            partialTranscript += event["delta"] as? String ?? ""
        case "conversation.item.input_audio_transcription.completed":
            let source = (event["transcript"] as? String ?? partialTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            partialTranscript = ""
            if !source.isEmpty {
                sourceTranscript += (sourceTranscript.isEmpty ? "" : "\n\n") + source
                enqueueTranslation(source)
            }
            if isBusy && !isRecording { finishSession() }
        case "conversation.item.input_audio_transcription.failed":
            let details = event["error"] as? [String: Any]
            errorMessage = details?["message"] as? String ?? "Trascrizione del segmento fallita."
            partialTranscript = ""
            if isBusy && !isRecording { finishSession() }
        case "session.updated":
            isAPIConnected = true
            guard !isRecording else { return }
            do {
                try startAudioCapture()
                isRecording = true
                isBusy = false
                status = "Trascrizione e traduzione"
            } catch {
                errorMessage = error.localizedDescription
                stopImmediately()
                status = "Errore"
            }
        case "error":
            let details = event["error"] as? [String: Any]
            let message = details?["message"] as? String ?? "Errore sconosciuto della Realtime API."
            if isBusy && !isRecording && message.localizedCaseInsensitiveContains("buffer") {
                finishSession()
                return
            }
            errorMessage = message
            stopImmediately()
            status = "Errore"
        default:
            break
        }
    }

    private func enqueueTranslation(_ source: String) {
        guard !apiKey.isEmpty else {
            errorMessage = "La chiave OpenAI non è più disponibile nel Keychain."
            return
        }

        let translationID = nextTranslationID
        nextTranslationID += 1
        pendingTranslations += 1
        RealtimeDebugLogger.logOutgoing([
            "type": "translation.request",
            "translation_id": translationID,
            "source": source
        ])
        let translationAPIKey = apiKey
        translationTasks[translationID] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let translated = try await Self.translateToEnglish(source, apiKey: translationAPIKey)
                guard !Task.isCancelled, let self else { return }
                self.finishTranslation(translationID, result: translated)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.finishTranslation(translationID, result: "", error: error)
            }
        }
    }

    private func finishTranslation(_ id: Int, result: String, error: Error? = nil) {
        translationTasks[id] = nil
        pendingTranslations = max(0, pendingTranslations - 1)
        completedTranslations[id] = result

        if let error {
            errorMessage = "Traduzione fallita: \(error.localizedDescription)"
            RealtimeDebugLogger.logIncoming([
                "type": "translation.error",
                "translation_id": id,
                "message": error.localizedDescription
            ])
        } else {
            RealtimeDebugLogger.logIncoming([
                "type": "translation.completed",
                "translation_id": id,
                "translation": result
            ])
        }

        while let translation = completedTranslations.removeValue(forKey: nextTranslationToDisplay) {
            nextTranslationToDisplay += 1
            guard !translation.isEmpty else { continue }
            transcript += (transcript.isEmpty ? "" : "\n\n") + translation
            hasReceivedTranslation = true
        }
    }

    nonisolated private static func translateToEnglish(_ source: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw TranscriberError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4.1-mini",
            "instructions": "Translate the user's text into natural English. Return only the translation, without notes or quotation marks.",
            "input": source
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let details = body?["error"] as? [String: Any]
            throw TranscriberError.translationFailed(details?["message"] as? String ?? "Risposta HTTP non valida.")
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = body["output"] as? [[String: Any]] else {
            throw TranscriberError.translationFailed("Testo tradotto assente nella risposta.")
        }
        let texts = output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
        }
        let translation = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw TranscriberError.translationFailed("Il modello ha restituito una traduzione vuota.")
        }
        return translation
    }

    private func handleFailure(_ error: Error) {
        guard webSocket != nil else { return }
        errorMessage = error.localizedDescription
        stopImmediately()
        status = "Connessione interrotta"
    }

    private func finishSession() {
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTask?.cancel()
        sendTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isBusy = false
        isAPIConnected = false
        status = "Pronto"
    }

    private func stopImmediately() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTask?.cancel()
        sendTask = nil
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        isBusy = false
        isAPIConnected = false
    }
}

private enum TranscriberError: LocalizedError {
    case invalidURL
    case unsupportedAudioFormat
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "URL della Realtime API non valido."
        case .unsupportedAudioFormat: "Il formato audio del microfono non è supportato."
        case .translationFailed(let message): message
        }
    }
}
