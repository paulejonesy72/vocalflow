import AppKit
import Combine

class HotkeyManager {
    private var flagsMonitor: Any?
    private var escapeMonitor: Any?
    private let appState: AppState
    private var triggerKeyIsDown = false
    /// Event tap for custom key-combination hotkeys (e.g. ⌃⌥Space). A tap — unlike a global
    /// NSEvent monitor — can swallow the key so it doesn't also type into the focused app.
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var hotkeyObservers: Set<AnyCancellable> = []
    private var reportedTapFailure = false

    /// Virtual key code for Esc (layout-independent).
    private static let escapeKeyCode: UInt16 = 53

    init(appState: AppState) {
        self.appState = appState
    }

    func startListening() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Esc anywhere in the system aborts an in-progress recording without
        // running transcription or pasting anything into the focused app.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            self?.cancelRecording()
        }
        // Install/remove the key tap whenever the trigger changes.
        appState.$selectedHotkey.combineLatest(appState.$customHotkey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshKeyTap() }
            .store(in: &hotkeyObservers)
    }

    /// The modifier key (key code + flag) that triggers recording via `flagsChanged`, or nil
    /// when the trigger is a custom key combination handled by the event tap.
    private var modifierTrigger: (keyCode: UInt16, flag: NSEvent.ModifierFlags)? {
        let hotkey = appState.selectedHotkey
        guard hotkey == .custom else { return (hotkey.keyCode, hotkey.modifierFlag) }
        guard let custom = appState.customHotkey,
              let flag = CustomHotkey.modifierFlag(forKeyCode: custom.keyCode) else { return nil }
        return (custom.keyCode, flag)
    }

    /// The custom key combination to watch with the event tap, if that's the active trigger.
    private var comboTrigger: CustomHotkey? {
        guard appState.selectedHotkey == .custom, let custom = appState.customHotkey,
              !custom.isModifierOnly else { return nil }
        return custom
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let trigger = modifierTrigger, event.keyCode == trigger.keyCode else { return }

        let isNowPressed = event.modifierFlags.contains(trigger.flag)

        if isNowPressed && !triggerKeyIsDown {
            triggerKeyIsDown = true
            startRecording()
        } else if !isNowPressed && triggerKeyIsDown {
            triggerKeyIsDown = false
            stopRecordingAndTranscribe()
        }
    }

    // MARK: - Custom key-combination trigger

    private func refreshKeyTap() {
        removeKeyTap()
        triggerKeyIsDown = false
        guard comboTrigger != nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleKeyTap(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Usually Accessibility isn't granted (yet) — e.g. right after a reinstall. Keep
            // retrying quietly so the hotkey starts working as soon as it's switched on.
            if !reportedTapFailure {
                reportedTapFailure = true
                appState.reportError("Custom hotkey needs Accessibility permission")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.keyTap == nil, self.comboTrigger != nil else { return }
                self.refreshKeyTap()
            }
            return
        }
        reportedTapFailure = false
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
    }

    private func removeKeyTap() {
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
        if let keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes) }
        keyTap = nil
        keyTapSource = nil
    }

    /// Runs on the main run loop. Returns nil to swallow the hotkey's own key events.
    private func handleKeyTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let combo = comboTrigger,
              UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == combo.keyCode
        else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            let held = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(CustomHotkey.relevantModifiers)
            guard triggerKeyIsDown || held == combo.modifierFlags else { return Unmanaged.passUnretained(event) }
            if !triggerKeyIsDown {
                triggerKeyIsDown = true
                startRecording()
            }
            return nil  // also swallows auto-repeat while held
        case .keyUp:
            guard triggerKeyIsDown else { return Unmanaged.passUnretained(event) }
            triggerKeyIsDown = false
            stopRecordingAndTranscribe()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func startRecording() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.recordingState = .recording

            // Connect WebSocket and start capture immediately. DeepgramService
            // queues frames internally until the socket opens, so audio captured
            // during the handshake isn't lost. Previously we delayed capture by
            // 150ms (to let the chime finish before muting), which dropped the
            // start of the user's speech.
            self.appState.transcriber.begin(
                apiKey: self.appState.deepgramAPIKey,
                model: self.appState.selectedModel,
                language: self.appState.selectedLanguage,
                keyterms: self.appState.focusWordTerms
            )
            do {
                try self.appState.audioEngine.startCapture(
                    deviceUID: self.appState.selectedAudioDeviceUID
                ) { [weak self] buffer, format in
                    self?.appState.transcriber.sendAudioBuffer(buffer, format: format)
                }
            } catch {
                self.handleCaptureFailure(error)
                return
            }

            // Output-side feedback runs in parallel and doesn't gate capture.
            // The chime is short enough that any pickup by the mic transcribes
            // to nothing meaningful; the mute still waits so the chime isn't
            // cut off mid-play.
            self.playFeedbackSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.appState.audioMuter.mute()
            }
        }
    }

    private func cancelRecording() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only act while actively recording — ignore Esc during transcription
            // or idle so we don't clobber a paste-in-flight or a normal Esc press.
            guard case .recording = self.appState.recordingState else { return }
            self.appState.audioEngine.stopCapture()
            self.appState.audioMuter.unmute()
            self.appState.transcriber.cancel()
            // Discard the in-flight press so the imminent hotkey-up doesn't try
            // to "stop" a session we just aborted.
            self.triggerKeyIsDown = false
            self.appState.recordingState = .idle
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        appState.audioMuter.unmute()
        appState.transcriber.cancel()
        let message = "Microphone failed: \(error.localizedDescription)"
        appState.recordingState = .error(message)
        appState.reportError(message)
        // Discard the in-flight press so the imminent key-up doesn't try to "stop"
        // a session that never started.
        triggerKeyIsDown = false
        // Auto-clear the error icon after a few seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if case .error = self.appState.recordingState {
                self.appState.recordingState = .idle
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appState.recordingState = .transcribing
            self.appState.audioEngine.stopCapture()
            self.appState.audioMuter.unmute()
            // Play chime after unmuting so it goes through
            self.playFeedbackSound()

            let finalTranscript = await self.appState.transcriber.closeStream()
            guard !finalTranscript.isEmpty else {
                self.appState.recordingState = .idle
                return
            }

            let provider = self.appState.selectedLLMProvider
            let apiKey = self.appState.currentLLMAPIKey
            let model = self.appState.currentLLMModel
            let hasLLMConfig = !apiKey.isEmpty && !model.isEmpty

            let options = LLMProcessingOptions(
                codeMix: (self.appState.codeMixEnabled && !self.appState.selectedCodeMix.isEmpty)
                    ? self.appState.selectedCodeMix : nil,
                fixSpelling: self.appState.correctionModeEnabled,
                fixGrammar: self.appState.grammarCorrectionEnabled,
                targetLanguage: (self.appState.targetLanguageEnabled && !self.appState.selectedTargetLanguage.isEmpty)
                    ? self.appState.selectedTargetLanguage : nil,
                customPrompt: self.appState.customSystemPrompt
            )

            var processed: String? = nil
            if hasLLMConfig && options.hasAnyStep {
                do {
                    processed = try await self.appState.llmService.processText(
                        finalTranscript,
                        options: options,
                        provider: provider,
                        apiKey: apiKey,
                        model: model
                    )
                } catch let error as APIError {
                    // Fall back to raw transcript so the user doesn't lose their dictation.
                    self.appState.reportError("\(provider.displayName): \(error.userMessage)")
                } catch {
                    self.appState.reportError("\(provider.displayName): \(error.localizedDescription)")
                }
            }

            // Apply the focus-words dictionary deterministically as the final pass — after any LLM
            // processing — so it's the authoritative spelling/expansion override and works even with
            // no LLM configured.
            let llmText = processed ?? finalTranscript
            let typed = FocusWordsDictionary.apply(self.appState.focusWords, to: llmText)
            self.appState.lastTranscript = typed
            self.appState.recordTranscript(raw: finalTranscript, processed: typed == finalTranscript ? nil : typed)
            self.appState.textInjector.inject(text: typed)
            // Watch the focused field: if the user fixes a word's spelling, learn it.
            self.appState.noteInjection(typed)
            self.appState.recordingState = .idle
        }
    }

    private func playFeedbackSound() {
        let name = appState.feedbackSoundName
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    deinit {
        removeKeyTap()
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
