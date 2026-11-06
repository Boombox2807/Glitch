import AVFoundation
import CoreAudio
import Carbon
import Speech

/// Push-to-talk speech recognition using Apple's on-device recognizer.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    /// Called on the main actor with the mic level (0...1) about 20 times a second.
    var onLevel: ((CGFloat) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// A fresh engine per session, released afterwards. Keeping one around holds the mic open,
    /// which keeps Bluetooth headphones stuck in low-quality "call" mode.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished: CheckedContinuation<Void, Never>?

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start() {
        guard !isListening, let recognizer, recognizer.isAvailable else { return }
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if AppSettings.shared.useBuiltInMic, let mic = Self.builtInMicID(), let unit = input.audioUnit {
            // Listening through the Mac's own mic leaves headphones in normal high-quality audio.
            var id = mic
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.write("mic: built-in \(status == noErr ? "selected" : "failed (\(status))")")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            Log.write("mic: engine failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.finished?.resume(); self.finished = nil }
            }
        }
        self.request = request
        isListening = true
    }

    /// The Mac's built-in microphone, if it has one.
    private static func builtInMicID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { id in
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            // Must have input channels (the built-in speakers are also "built in").
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr && sSize > 0
        }
    }

    /// RMS of the buffer mapped from roughly -50…0 dB onto 0…1.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(max((db + 50) / 50, 0), 1))
    }

    /// Stops listening and returns the final transcript.
    func stop() async -> String {
        guard isListening else { return "" }
        isListening = false
        Log.write("mic: stopping engine")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        engine = nil   // releases the input device
        request?.endAudio()

        // Wait for the recognizer's final result, but never more than 1.5s.
        await withCheckedContinuation { continuation in
            finished = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.finished?.resume(); self?.finished = nil
            }
        }
        task?.cancel()
        task = nil
        request = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Global hotkeys via Carbon, which needs no Accessibility permission.
enum HotKey {
    private struct Handlers { let press: () -> Void; let release: (() -> Void)? }
    private static var handlers: [UInt32: Handlers] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    /// Registers a global hotkey and returns its id (for `unregister`).
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, onPress: @escaping () -> Void,
                         onRelease: (() -> Void)? = nil) -> UInt32 {
        installHandlerOnce()
        let id = nextID
        nextID += 1
        handlers[id] = Handlers(press: onPress, release: onRelease)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                            EventHotKeyID(signature: OSType(0x474C_5443), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
        return id
    }

    static func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let h = HotKey.handlers[hotKeyID.id] else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { h.press() } else { h.release?() }
            return noErr
        }, types.count, &types, nil, nil)
    }
}
