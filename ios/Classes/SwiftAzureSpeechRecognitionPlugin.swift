import AVFoundation
import Flutter
import MicrosoftCognitiveServicesSpeech
import UIKit

@available(iOS 13.0, *)
struct SimpleRecognitionTask {
    var task: Task<Void, Never>
    var isCanceled: Bool
}

@available(iOS 13.0, *)
public class SwiftAzureSpeechRecognitionPlugin: NSObject, FlutterPlugin {
    var azureChannel: FlutterMethodChannel
    var continousListeningStarted: Bool = false
    var continousSpeechRecognizer: SPXSpeechRecognizer? = nil
    var simpleRecognitionTasks: [String: SimpleRecognitionTask] = [:]

    var recognizer: SPXKeywordRecognizer?
    var speechConfig: SPXSpeechConfiguration?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "azure_speech_recognition", binaryMessenger: registrar.messenger())
        let instance: SwiftAzureSpeechRecognitionPlugin = SwiftAzureSpeechRecognitionPlugin(
            azureChannel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(azureChannel: FlutterMethodChannel) {
        self.azureChannel = azureChannel
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let speechSubscriptionKey = args?["subscriptionKey"] as? String ?? ""
        let serviceRegion = args?["region"] as? String ?? ""
        let lang = args?["language"] as? String ?? ""
        let timeoutMs = args?["timeout"] as? String ?? ""
        let referenceText = args?["referenceText"] as? String ?? ""
        let phonemeAlphabet = args?["phonemeAlphabet"] as? String ?? "IPA"
        let granularityString = args?["granularity"] as? String ?? "phoneme"
        let enableMiscue = args?["enableMiscue"] as? Bool ?? false
        let nBestPhonemeCount = args?["nBestPhonemeCount"] as? Int
        var granularity: SPXPronunciationAssessmentGranularity
        if granularityString == "text" {
            granularity = SPXPronunciationAssessmentGranularity.fullText
        } else if granularityString == "word" {
            granularity = SPXPronunciationAssessmentGranularity.word
        } else {
            granularity = SPXPronunciationAssessmentGranularity.phoneme
        }
        if call.method == "simpleVoice" {
            print("Called simpleVoice")
            simpleSpeechRecognition(
                speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion,
                lang: lang, timeoutMs: timeoutMs)
            result(true)
        } else if call.method == "simpleVoiceWithAssessment" {
            print("Called simpleVoiceWithAssessment")
            simpleSpeechRecognitionWithAssessment(
                referenceText: referenceText, phonemeAlphabet: phonemeAlphabet,
                granularity: granularity, enableMiscue: enableMiscue,
                speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion,
                lang: lang, timeoutMs: timeoutMs, nBestPhonemeCount: nBestPhonemeCount)
            result(true)
        } else if call.method == "isContinuousRecognitionOn" {
            print("Called isContinuousRecognitionOn: \(continousListeningStarted)")
            result(continousListeningStarted)
        } else if call.method == "continuousStream" {
            print("Called continuousStream")
            continuousStream(
                speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion,
                lang: lang)
            result(true)
        } else if call.method == "continuousStreamWithAssessment" {
            print("Called continuousStreamWithAssessment")
            continuousStreamWithAssessment(
                referenceText: referenceText, phonemeAlphabet: phonemeAlphabet,
                granularity: granularity, enableMiscue: enableMiscue,
                speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion,
                lang: lang, nBestPhonemeCount: nBestPhonemeCount)
            result(true)
        } else if call.method == "stopContinuousStream" {
            stopContinuousStream(flutterResult: result)
//            stopKeywordRecognition()
        } else if call.method == "startKeywordRecognition" {
            if let args = call.arguments as? [String: Any],
                let modelPath = args["keywordModelPath"] as? String
            {
                initKeywordRecognition(
                    speechSubscriptionKey: speechSubscriptionKey,
                    serviceRegion: serviceRegion,
                    modelPath: modelPath
                )
            }
            result(true)
        } else if call.method == "stopKeywordRecognition" {
            stopKeywordRecognition()
            result(true)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    private func cancelActiveSimpleRecognitionTasks() {
        print("Cancelling any active tasks")
        for taskId in simpleRecognitionTasks.keys {
            print("Cancelling task \(taskId)")
            simpleRecognitionTasks[taskId]?.task.cancel()
            simpleRecognitionTasks[taskId]?.isCanceled = true
        }
    }

    private func simpleSpeechRecognition(
        speechSubscriptionKey: String, serviceRegion: String, lang: String, timeoutMs: String
    ) {
        print("Created new recognition task")
        cancelActiveSimpleRecognitionTasks()
        let taskId = UUID().uuidString
        let task = Task {
            print("Started recognition with task ID \(taskId)")
            var speechConfig: SPXSpeechConfiguration?
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(
                    AVAudioSession.Category.record, mode: AVAudioSession.Mode.default,
                    options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
                // Initialize speech recognizer and specify correct subscription key and service region
                try speechConfig = SPXSpeechConfiguration(
                    subscription: speechSubscriptionKey, region: serviceRegion)
            } catch {
                print("error \(error) happened")
                speechConfig = nil
            }
            speechConfig?.speechRecognitionLanguage = lang
            speechConfig?.setPropertyTo(
                timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            let audioConfig = SPXAudioConfiguration()
            let reco = try! SPXSpeechRecognizer(
                speechConfiguration: speechConfig!, audioConfiguration: audioConfig)

            reco.addRecognizingEventHandler { reco, evt in
                if self.simpleRecognitionTasks[taskId]?.isCanceled ?? false {  // Discard intermediate results if the task was cancelled
                    print("Ignoring partial result. TaskID: \(taskId)")
                } else {
                    print(
                        "Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)"
                    )
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
            }

            let result = try! reco.recognizeOnce()
            if Task.isCancelled {
                print("Ignoring final result. TaskID: \(taskId)")
            } else {
                print(
                    "Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)"
                )
                if result.reason != SPXResultReason.recognizedSpeech {
                    let cancellationDetails = try! SPXCancellationDetails(
                        fromCanceledRecognitionResult: result)
                    print(
                        "Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)"
                    )
                    print("Did you set the speech resource key and region values?")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                } else {
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                }

            }
            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }
        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
    }

    private func simpleSpeechRecognitionWithAssessment(
        referenceText: String, phonemeAlphabet: String,
        granularity: SPXPronunciationAssessmentGranularity, enableMiscue: Bool,
        speechSubscriptionKey: String, serviceRegion: String, lang: String, timeoutMs: String,
        nBestPhonemeCount: Int?
    ) {
        print("Created new recognition task")
        cancelActiveSimpleRecognitionTasks()
        let taskId = UUID().uuidString
        let task = Task {
            print("Started recognition with task ID \(taskId)")
            var speechConfig: SPXSpeechConfiguration?
            var pronunciationAssessmentConfig: SPXPronunciationAssessmentConfiguration?
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(
                    AVAudioSession.Category.record, mode: AVAudioSession.Mode.default,
                    options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
                // Initialize speech recognizer and specify correct subscription key and service region
                try speechConfig = SPXSpeechConfiguration(
                    subscription: speechSubscriptionKey, region: serviceRegion)
                try pronunciationAssessmentConfig = SPXPronunciationAssessmentConfiguration.init(
                    referenceText,
                    gradingSystem: SPXPronunciationAssessmentGradingSystem.hundredMark,
                    granularity: granularity,
                    enableMiscue: enableMiscue)
            } catch {
                print("error \(error) happened")
                speechConfig = nil
            }
            pronunciationAssessmentConfig?.phonemeAlphabet = phonemeAlphabet

            if nBestPhonemeCount != nil {
                pronunciationAssessmentConfig?.nbestPhonemeCount = nBestPhonemeCount!
            }

            speechConfig?.speechRecognitionLanguage = lang
            speechConfig?.setPropertyTo(
                timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            let audioConfig = SPXAudioConfiguration()
            let reco = try! SPXSpeechRecognizer(
                speechConfiguration: speechConfig!, audioConfiguration: audioConfig)
            try! pronunciationAssessmentConfig?.apply(to: reco)

            reco.addRecognizingEventHandler { reco, evt in
                if self.simpleRecognitionTasks[taskId]?.isCanceled ?? false {  // Discard intermediate results if the task was cancelled
                    print("Ignoring partial result. TaskID: \(taskId)")
                } else {
                    print(
                        "Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)"
                    )
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
            }

            let result = try! reco.recognizeOnce()
            if Task.isCancelled {
                print("Ignoring final result. TaskID: \(taskId)")
            } else {
                print(
                    "Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)"
                )
                let pronunciationAssessmentResultJson = result.properties?.getPropertyBy(
                    SPXPropertyId.speechServiceResponseJsonResult)
                print(
                    "pronunciationAssessmentResultJson: \(pronunciationAssessmentResultJson ?? "(no result)")"
                )
                if result.reason != SPXResultReason.recognizedSpeech {
                    let cancellationDetails = try! SPXCancellationDetails(
                        fromCanceledRecognitionResult: result)
                    print(
                        "Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)"
                    )
                    print("Did you set the speech resource key and region values?")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                    self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: "")
                } else {
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    self.azureChannel.invokeMethod(
                        "speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
                }

            }
            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }
        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
    }

    private func stopContinuousStream(flutterResult: FlutterResult) {
        if continousListeningStarted {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
                flutterResult(true)
            } catch {
                print("Error occurred stopping continous recognition")
            }
        }
    }

    private func continuousStream(
        speechSubscriptionKey: String, serviceRegion: String, lang: String
    ) {
        if continousListeningStarted {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            } catch {
                print("Error occurred stopping continous recognition")
            }
        } else {
            print("Starting continous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(
                    AVAudioSession.Category.record, mode: AVAudioSession.Mode.default,
                    options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
            } catch {
                print("An unexpected error occurred")
            }

            let speechConfig = try! SPXSpeechConfiguration(
                subscription: speechSubscriptionKey, region: serviceRegion)

            speechConfig.speechRecognitionLanguage = lang

            let audioConfig = SPXAudioConfiguration()

            continousSpeechRecognizer = try! SPXSpeechRecognizer(
                speechConfiguration: speechConfig, audioConfiguration: audioConfig)
            continousSpeechRecognizer!.addRecognizingEventHandler { reco, evt in
                print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
            }
            continousSpeechRecognizer!.addRecognizedEventHandler({ reco, evt in
                let res = evt.result.text
                print("final result \(res!)")
                self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: res)
            })
            print("Listening...")
            try! continousSpeechRecognizer!.startContinuousRecognition()
            self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
            continousListeningStarted = true
        }
    }

    private func continuousStreamWithAssessment(
        referenceText: String, phonemeAlphabet: String,
        granularity: SPXPronunciationAssessmentGranularity, enableMiscue: Bool,
        speechSubscriptionKey: String, serviceRegion: String, lang: String, nBestPhonemeCount: Int?
    ) {
        print("Continuous recognition started: \(continousListeningStarted)")
        if continousListeningStarted {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            } catch {
                print("Error occurred stopping continous recognition")
            }
        } else {
            print("Starting continous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(
                    AVAudioSession.Category.record, mode: AVAudioSession.Mode.default,
                    options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")

                let speechConfig = try SPXSpeechConfiguration(
                    subscription: speechSubscriptionKey, region: serviceRegion)
                speechConfig.speechRecognitionLanguage = lang

                let pronunciationAssessmentConfig =
                    try SPXPronunciationAssessmentConfiguration.init(
                        referenceText,
                        gradingSystem: SPXPronunciationAssessmentGradingSystem.hundredMark,
                        granularity: granularity,
                        enableMiscue: enableMiscue)
                pronunciationAssessmentConfig.phonemeAlphabet = phonemeAlphabet

                if nBestPhonemeCount != nil {
                    pronunciationAssessmentConfig.nbestPhonemeCount = nBestPhonemeCount!
                }

                let audioConfig = SPXAudioConfiguration()

                continousSpeechRecognizer = try SPXSpeechRecognizer(
                    speechConfiguration: speechConfig, audioConfiguration: audioConfig)
                try pronunciationAssessmentConfig.apply(to: continousSpeechRecognizer!)

                continousSpeechRecognizer!.addRecognizingEventHandler { reco, evt in
                    print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
                continousSpeechRecognizer!.addRecognizedEventHandler({ reco, evt in
                    let result = evt.result
                    print(
                        "Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)"
                    )
                    let pronunciationAssessmentResultJson = result.properties?.getPropertyBy(
                        SPXPropertyId.speechServiceResponseJsonResult)
                    print(
                        "pronunciationAssessmentResultJson: \(pronunciationAssessmentResultJson ?? "(no result)")"
                    )
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    self.azureChannel.invokeMethod(
                        "speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
                })
                print("Listening...")
                try continousSpeechRecognizer!.startContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                continousListeningStarted = true
            } catch {
                print("An unexpected error occurred: \(error)")
            }
        }
    }

    func initKeywordRecognition(
        speechSubscriptionKey: String,
        serviceRegion: String,
        modelPath: String
    ) {
        copyAssetToTemp(assetKey: modelPath) { tempFilePath in
            guard let filePath = tempFilePath else {
                print("Failed to load asset from Flutter")
                self.azureChannel.invokeMethod("speech.recognizedKeywordInvalidFile", arguments: "")
                return
            }

            self.startKeywordRecognition(
                speechSubscriptionKey: speechSubscriptionKey,
                serviceRegion: serviceRegion,
                tempFilePath: tempFilePath!
            )
            return

        }
    }

    func startKeywordRecognition(
        speechSubscriptionKey: String,
        serviceRegion: String,
        tempFilePath: String
    ) {
        print("Starting KeywordRecognition of file " + tempFilePath)
        do {
            do {
                try self.speechConfig = SPXSpeechConfiguration(
                    subscription: speechSubscriptionKey, region: serviceRegion)
            } catch {
                print("error \(error) happened")
                self.speechConfig = nil
            }
            
            let audioConfig = SPXAudioConfiguration()
            let keywordModel = try SPXKeywordRecognitionModel(fromFile: tempFilePath)
            self.recognizer = try! SPXKeywordRecognizer(audioConfig)

            try self.recognizer?.recognizeOnceAsync(
                { result in
                    
                    if result.reason == SPXResultReason.recognizedKeyword {
                        print("Wake word recognized: \(result.text ?? "Unknown")")
                        self.azureChannel.invokeMethod("speech.onKeyword", arguments: "")
                    } else if (result.reason == SPXResultReason.canceled) {
                        print("canceled current rec process")
                        return;
                    }

                    print("starting again")
                    /// Start again the rec
                    self.startKeywordRecognition(
                        speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion,
                        tempFilePath: tempFilePath
                    )
                }, keywordModel: keywordModel)
        } catch {
            self.azureChannel.invokeMethod("speech.recognizedKeywordError", arguments: "")
//            DispatchQueue.main.async {
//                
//            }
            
        }
        return
    }

    func stopKeywordRecognition() {
        do {
            try recognizer?.stopRecognitionAsync({ b, error in return })
            recognizer = nil
            print("Stopped Wake Word Detection.")
//            self.azureChannel.invokeMethod("speech.stoppedKeywordRecognition", arguments: "")
        } catch {
//            self.azureChannel.invokeMethod("speech.stoppedKeywordRecognitionError", arguments: "")
        }
    }

    func copyAssetToTemp(assetKey: String, completion: @escaping (String?) -> Void) {
        guard let flutterAssetPath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
            print("Error: Asset not found in Flutter bundle")
            completion(nil)
            return
        }

        let fileManager = FileManager.default
        let tempDirectory = NSTemporaryDirectory()
        let tempFilePath = (tempDirectory as NSString).appendingPathComponent(assetKey)

        if !fileManager.fileExists(atPath: tempFilePath) {
            do {
                try fileManager.copyItem(atPath: flutterAssetPath, toPath: tempFilePath)
                print("File copied to: \(tempFilePath)")
            } catch {
                print("Error copying file: \(error.localizedDescription)")
                completion(nil)
                return
            }
        }
        completion(tempFilePath)
    }

}
