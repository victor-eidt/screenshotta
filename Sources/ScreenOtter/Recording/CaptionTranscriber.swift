import AVFoundation
import Speech

/// A language captions can be transcribed in.
nonisolated struct CaptionLanguage: Identifiable, Hashable, Sendable {
    /// A locale identifier, "en_US", "pt_BR".
    let id: String

    /// "English (United States)", in the user's own language.
    var name: String { Locale.current.localizedString(forIdentifier: id) ?? id }
}

nonisolated enum CaptionTranscriberError: LocalizedError {
    case unsupportedLanguage
    case notAuthorized
    case nothingHeard

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: "This Mac can't transcribe that language."
        case .notAuthorized: "Speech Recognition is off for ScreenOtter. Allow it in Privacy & Security › Speech Recognition."
        case .nothingHeard: "No speech was found in the microphone track."
        }
    }
}

/// Turns the microphone track into words with their times, on the Mac: nothing is sent anywhere.
/// macOS 26 uses SpeechAnalyzer (its language model is downloaded once, the first time a language is used);
/// earlier versions use on-device SFSpeechRecognizer.
nonisolated enum CaptionTranscriber {
    enum Phase: Equatable, Sendable {
        /// Fetching the language model, 0 to 1.
        case downloading(Double)
        /// Listening through the track, 0 to 1 when known.
        case transcribing(Double?)
    }

    private static let languageKey = "captionLanguage"

    /// The languages this Mac can transcribe, by name.
    static func languages() async -> [CaptionLanguage] {
        let locales: [Locale]
        if #available(macOS 26, *) {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = Array(SFSpeechRecognizer.supportedLocales())
        }
        return Set(locales.map { CaptionLanguage(id: $0.identifier(.icu)) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The language to offer: the one used last, else the closest to the Mac's own.
    static func preferred(in languages: [CaptionLanguage]) -> CaptionLanguage? {
        if let last = UserDefaults.standard.string(forKey: languageKey), let match = languages.first(where: { $0.id == last }) {
            return match
        }
        let current = Locale.current
        let language = current.language.languageCode?.identifier ?? "en"
        let region = current.region?.identifier
        return languages.first { $0.id == "\(language)_\(region ?? "")" }
            ?? languages.first { $0.id == "\(language)_US" }
            ?? languages.first { $0.id.hasPrefix(language + "_") || $0.id == language }
            ?? languages.first { $0.id == "en_US" }
            ?? languages.first
    }

    /// The words of the track at `url`, in seconds from its start.
    static func transcribe(_ url: URL, language: CaptionLanguage, phase: @escaping @Sendable (Phase) -> Void) async throws -> [CaptionWord] {
        UserDefaults.standard.set(language.id, forKey: languageKey)
        let locale = Locale(identifier: language.id)
        let raw: [CaptionWord]
        if #available(macOS 26, *) {
            raw = try await analyze(url, locale: locale, phase: phase)
        } else {
            raw = try await recognize(url, locale: locale, phase: phase)
        }
        let words = tidy(raw)
        guard !words.isEmpty else { throw CaptionTranscriberError.nothingHeard }
        return words
    }

    /// Trims the spaces recognizers put before words, and attaches stray punctuation to the word before it.
    static func tidy(_ words: [CaptionWord]) -> [CaptionWord] {
        var result: [CaptionWord] = []
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains), !result.isEmpty {
                result[result.count - 1].text += text
                result[result.count - 1].end = max(result[result.count - 1].end, word.end)
                continue
            }
            result.append(CaptionWord(text: text, start: word.start, end: max(word.end, word.start)))
        }
        return result
    }

    // MARK: - macOS 26

    @available(macOS 26, *)
    private static func analyze(_ url: URL, locale: Locale, phase: @escaping @Sendable (Phase) -> Void) async throws -> [CaptionWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CaptionTranscriberError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            phase(.downloading(0))
            let watcher = Task {
                while !Task.isCancelled {
                    phase(.downloading(request.progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        phase(.transcribing(0))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    words.append(CaptionWord(text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds))
                }
                if duration > 0 { phase(.transcribing(min(result.range.end.seconds / duration, 1))) }
            }
            return words
        }
        try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        } onCancel: {
            collect.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        return try await collect.value
    }

    // MARK: - macOS 14 and 15

    private static func recognize(_ url: URL, locale: Locale, phase: @escaping @Sendable (Phase) -> Void) async throws -> [CaptionWord] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw CaptionTranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionTranscriberError.unsupportedLanguage
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // On the Mac when it can be; otherwise macOS uses Apple's servers, as dictation does.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        phase(.transcribing(nil))

        let once = Once()
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.run { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    once.run { continuation.resume(returning: result) }
                }
            }
        }
        return result.bestTranscription.segments.map {
            CaptionWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
        }
    }

    /// Runs a block the first time only: the recognizer can call back more than once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ block: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { block() }
        }
    }
}
