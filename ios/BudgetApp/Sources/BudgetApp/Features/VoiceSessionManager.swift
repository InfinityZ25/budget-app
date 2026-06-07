import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionManager {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case speaking
        case error

        var label: String {
            switch self {
            case .connecting, .connected:
                "Listening"
            case .speaking:
                "Speaking"
            case .idle, .error:
                "Off"
            }
        }
    }

    var status: Status = .idle
    var message = "Tap the microphone to start a Grok voice session."
    var transcript = ""
    var model = ""
    var voice = ""
    @ObservationIgnored var onUserTranscript: ((String) -> Void)?
    @ObservationIgnored var onAssistantDelta: ((String) -> Void)?
    @ObservationIgnored var onAssistantFinished: (() -> Void)?

    private let api = APIClient.local
    private let sampleRate: Double = 24_000
    private let webSocketSendQueue = DispatchQueue(label: "BudgetApp.voice.webSocketSend", qos: .userInitiated)
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioInput: VoiceAudioInput?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var currentAssistantTranscript = ""
    private var sessionGeneration = 0
    private var responseIsActive = false
    private var responseDoneReceived = false
    private var pendingPlaybackBuffers = 0

    var isActive: Bool {
        status == .connecting || status == .connected || status == .speaking
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        sessionGeneration += 1
        let generation = sessionGeneration
        status = .connecting
        transcript = ""
        currentAssistantTranscript = ""
        responseIsActive = false
        responseDoneReceived = false
        pendingPlaybackBuffers = 0
        message = "Requesting microphone access…"
        guard await requestMicrophoneAccess() else {
            status = .error
            message = "Microphone access denied. Enable it in Settings and tap again."
            return
        }
        do {
            try configureAudioSession()
            try startPlayback()
            message = "Creating secure voice session…"
            let session = try await api.createVoiceSession()
            model = session.model
            voice = session.voice
            var request = URLRequest(url: session.websocketURL)
            request.timeoutInterval = 10
            request.setValue("xai-client-secret.\(session.clientSecret)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let socket = URLSession.shared.webSocketTask(with: request)
            webSocket = socket
            socket.resume()
            receiveTask = Task { await receiveLoop(socket: socket, generation: generation) }
            try await send(session.session)
            let input = VoiceAudioInput(sampleRate: sampleRate)
            try input.start(
                socket: socket,
                onSpeechStart: { [weak self] in
                    Task { @MainActor in
                        self?.handleLocalSpeechStarted(generation: generation)
                    }
                },
                onSpeechEnd: { [weak self] in
                    Task { @MainActor in
                        await self?.handleLocalSpeechEnded(generation: generation)
                    }
                }
            )
            audioInput = input
            status = .connected
            message = "Listening. Speak naturally; audio is streaming to \(session.model)."
        } catch {
            status = .error
            message = error.localizedDescription
            stop(resetMessage: false)
        }
    }

    func stop() {
        stop(resetMessage: true)
    }

    private func stop(resetMessage: Bool) {
        sessionGeneration += 1
        responseIsActive = false
        responseDoneReceived = false
        pendingPlaybackBuffers = 0
        receiveTask?.cancel()
        receiveTask = nil
        audioInput?.stop()
        audioInput = nil
        playerNode?.stop()
        playbackEngine?.stop()
        playerNode = nil
        playbackEngine = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = .idle
        if resetMessage {
            message = "Tap the microphone to start a Grok voice session."
        }
    }

    private func handleLocalSpeechStarted(generation: Int) {
        guard generation == sessionGeneration, isActive else { return }
        if responseIsActive || status == .speaking {
            cancelActiveResponse()
        }
        status = .connected
        currentAssistantTranscript = ""
        message = "Listening…"
    }

    private func handleLocalSpeechEnded(generation: Int) async {
        guard generation == sessionGeneration, isActive, !responseIsActive else { return }
        responseIsActive = true
        responseDoneReceived = false
        pendingPlaybackBuffers = 0
        message = "Thinking…"
        try? await sendRawJSON(["type": "input_audio_buffer.commit"])
        try? await sendRawJSON(["type": "response.create"])
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func startPlayback() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
        playbackEngine = engine
        playerNode = player
    }

    private func send<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
    }

    private func sendRawJSON(_ payload: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await sendRawJSONString(text)
    }

    private func sendRawJSONString(_ text: String) async throws {
        guard let webSocket else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocketSendQueue.async {
                webSocket.send(.string(text)) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            do {
                let event = try await socket.receive()
                if case let .string(text) = event, generation == sessionGeneration {
                    await handleEvent(text, generation: generation)
                }
            } catch {
                await MainActor.run {
                    if isActive, generation == sessionGeneration {
                        status = .error
                        message = error.localizedDescription
                    }
                }
                return
            }
        }
    }

    private func handleEvent(_ text: String, generation: Int) async {
        guard generation == sessionGeneration else { return }
        guard
            let data = text.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = event["type"] as? String
        else {
            return
        }

        switch type {
        case "session.created", "session.updated":
            status = .connected
            message = "Listening. Speak naturally; audio is streaming."
        case "input_audio_buffer.speech_started":
            handleLocalSpeechStarted(generation: generation)
        case "input_audio_buffer.speech_stopped":
            await handleLocalSpeechEnded(generation: generation)
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String, !text.isEmpty {
                transcript = text
                message = "Thinking…"
                onUserTranscript?(text)
            }
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String {
                responseIsActive = true
                status = .speaking
                message = "Speaking…"
                playPCM16(base64: delta, generation: generation)
            }
        case "response.output_audio.done", "response.audio.done":
            responseDoneReceived = true
            finishResponseIfPlaybackDrained()
        case "response.done":
            responseDoneReceived = true
            finishResponseIfPlaybackDrained()
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta", "response.text.delta":
            if let delta = event["delta"] as? String {
                currentAssistantTranscript += delta
                onAssistantDelta?(delta)
            }
        case "error":
            status = .error
            message = errorMessage(from: event)
        default:
            break
        }
    }

    private func cancelActiveResponse() {
        playerNode?.stop()
        playerNode?.play()
        pendingPlaybackBuffers = 0
        responseDoneReceived = false
        responseIsActive = false
        try? sendRawJSONStringSync(#"{"type":"response.cancel"}"#)
    }

    private func sendRawJSONStringSync(_ text: String) throws {
        guard let webSocket else { return }
        webSocketSendQueue.async {
            webSocket.send(.string(text)) { _ in }
        }
    }

    private func finishResponseIfPlaybackDrained() {
        guard responseDoneReceived, pendingPlaybackBuffers == 0 else { return }
        status = .connected
        message = "Listening. Ask another question."
        currentAssistantTranscript = ""
        responseIsActive = false
        responseDoneReceived = false
        onAssistantFinished?()
    }

    private func errorMessage(from event: [String: Any]) -> String {
        if let message = event["message"] as? String {
            return message
        }
        if let error = event["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return "Voice session error."
    }

    private func playPCM16(base64: String, generation: Int) {
        guard
            let data = Data(base64Encoded: base64),
            let playerNode,
            let buffer = Self.floatBuffer(fromPCM16: data, sampleRate: sampleRate)
        else {
            return
        }
        pendingPlaybackBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.sessionGeneration else { return }
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                self.finishResponseIfPlaybackDrained()
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    nonisolated static func pcm16Data(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputSampleRate: Double) -> Data {
        guard let floatChannelData = buffer.floatChannelData else { return Data() }
        let inputFrameCount = Int(buffer.frameLength)
        guard inputFrameCount > 0 else { return Data() }
        let channelCount = max(1, Int(inputFormat.channelCount))
        let ratio = inputFormat.sampleRate / outputSampleRate
        let outputFrameCount = max(1, Int(Double(inputFrameCount) / ratio))
        var output = Data(capacity: outputFrameCount * 2)

        for outputIndex in 0..<outputFrameCount {
            let inputIndex = min(inputFrameCount - 1, Int(Double(outputIndex) * ratio))
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += floatChannelData[channel][inputIndex]
            }
            sample /= Float(channelCount)
            let clamped = max(-1, min(1, sample))
            var intSample = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { output.append(contentsOf: $0) }
        }
        return output
    }

    nonisolated private static func floatBuffer(fromPCM16 data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard
            frameCount > 0,
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress, let channel = buffer.floatChannelData?[0] else { return }
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }
        return buffer
    }
}

private final class VoiceAudioInput {
    private let sampleRate: Double
    private let voiceThreshold: Float = 0.012
    private let silenceInterval: TimeInterval = 0.9
    private let minimumSpeechInterval: TimeInterval = 0.25
    private let audioEncodingQueue = DispatchQueue(label: "BudgetApp.voice.audioEncoding", qos: .userInitiated)
    private let webSocketSendQueue = DispatchQueue(label: "BudgetApp.voice.webSocketSend", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var speechStartedAt: TimeInterval?
    private var lastVoiceAt: TimeInterval?
    private var waitingForResponse = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func start(socket: URLSessionWebSocketTask, onSpeechStart: @escaping () -> Void, onSpeechEnd: @escaping () -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let outputSampleRate = sampleRate
        let audioEncodingQueue = audioEncodingQueue
        let webSocketSendQueue = webSocketSendQueue

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            let level = Self.rootMeanSquare(buffer: buffer)
            let now = Date().timeIntervalSinceReferenceDate
            if level > self.voiceThreshold {
                if self.speechStartedAt == nil {
                    onSpeechStart()
                }
                self.speechStartedAt = self.speechStartedAt ?? now
                self.lastVoiceAt = now
                self.waitingForResponse = false
            } else if
                let speechStartedAt = self.speechStartedAt,
                let lastVoiceAt = self.lastVoiceAt,
                !self.waitingForResponse,
                now - speechStartedAt >= self.minimumSpeechInterval,
                now - lastVoiceAt >= self.silenceInterval
            {
                self.waitingForResponse = true
                self.speechStartedAt = nil
                self.lastVoiceAt = nil
                onSpeechEnd()
            }

            let pcmData = VoiceSessionManager.pcm16Data(buffer: buffer, inputFormat: format, outputSampleRate: outputSampleRate)
            guard !pcmData.isEmpty else { return }
            audioEncodingQueue.async {
                let payload = ["type": "input_audio_buffer.append", "audio": pcmData.base64EncodedString()]
                guard
                    let data = try? JSONSerialization.data(withJSONObject: payload),
                    let text = String(data: data, encoding: .utf8)
                else {
                    return
                }
                webSocketSendQueue.async {
                    socket.send(.string(text)) { _ in }
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private static func rootMeanSquare(buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frameCount {
                sum += samples[index] * samples[index]
            }
        }
        return sqrt(sum / Float(frameCount * channelCount))
    }
}
