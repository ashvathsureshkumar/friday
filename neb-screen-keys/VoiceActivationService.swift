//
//  VoiceActivationService.swift
//  neb-screen-keys
//

import Foundation
import Speech
import AVFoundation

final class VoiceActivationService: NSObject {
    // Speech recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // Wake word configuration
    private let wakePhrase = "daddy's home"
    private var isListening = false
    
    // Callbacks
    var onWakeWordDetected: (() -> Void)?
    
    override init() {
        super.init()
        Logger.shared.log(.system, "🎤 VoiceActivationService initialized")
    }
    
    func requestPermissions(completion: @escaping (Bool) -> Void) {
        // Request speech recognition permission
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    Logger.shared.log(.system, "✅ Speech recognition authorized")
                    completion(true)
                case .denied:
                    Logger.shared.log(.system, "❌ Speech recognition denied by user")
                    completion(false)
                case .restricted:
                    Logger.shared.log(.system, "❌ Speech recognition restricted on this device")
                    completion(false)
                case .notDetermined:
                    Logger.shared.log(.system, "⚠️ Speech recognition authorization not determined")
                    completion(false)
                @unknown default:
                    completion(false)
                }
            }
        }
    }
    
    func startListening() {
        guard !isListening else {
            Logger.shared.log(.system, "⚠️ Already listening for wake word")
            return
        }
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.shared.log(.system, "❌ Audio session setup failed: \(error.localizedDescription)")
            return
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            Logger.shared.log(.system, "❌ Unable to create speech recognition request")
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Get audio input node
        let inputNode = audioEngine.inputNode
        
        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let transcription = result.bestTranscription.formattedString.lowercased()
                Logger.shared.log(.system, "🎤 Heard: \(transcription)")
                
                // Check if wake phrase was detected
                if transcription.contains(self.wakePhrase) {
                    Logger.shared.log(.system, "🎉 WAKE WORD DETECTED: '\(self.wakePhrase)'")
                    
                    // Stop listening temporarily
                    self.stopListening()
                    
                    // Notify callback
                    DispatchQueue.main.async {
                        self.onWakeWordDetected?()
                    }
                }
            }
            
            if error != nil {
                // Restart listening on error
                Logger.shared.log(.system, "⚠️ Speech recognition error, restarting...")
                self.stopListening()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.startListening()
                }
            }
        }
        
        // Configure audio format
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            Logger.shared.log(.system, "🎤 Started listening for wake word: '\(wakePhrase)'")
        } catch {
            Logger.shared.log(.system, "❌ Audio engine failed to start: \(error.localizedDescription)")
        }
    }
    
    func stopListening() {
        guard isListening else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        
        Logger.shared.log(.system, "🎤 Stopped listening for wake word")
    }
    
    deinit {
        stopListening()
    }
}

