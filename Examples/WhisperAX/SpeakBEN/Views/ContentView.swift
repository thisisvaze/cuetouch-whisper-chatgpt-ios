//
//  ContentView.swift
//
//
//
//  Created by Aaditya Vaze on 2024-03-27.
//

import SwiftUI
import WhisperKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AVFoundation
extension Color {
        init(hex: UInt, alpha: Double = 1) {
            self.init(
                .sRGB,
                red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 08) & 0xff) / 255,
                blue: Double((hex >> 00) & 0xff) / 255,
                opacity: alpha
            )
        }
    }
struct ContentView: View {
    @State var whisperKit: WhisperKit? = nil
    @State var isRecording: Bool = false
    @State var isTranscribing: Bool = false
    @State var currentText: String = ""
     @StateObject public var model = DataModel()
 
    private static let barHeightFactor = 0.15
    // TODO: Make this configurable in the UI
    @State var modelStorage: String = "huggingface/models/argmaxinc/whisperkit-coreml"
    
    //show tactile feedback
    @State var prompt: String = """
    Help me with my question. Give a short answer keep it within 30 words.
    """
    
    @State private var modelState: ModelState = .unloaded
    @State private var localModels: [String] = []
    @State private var isRequestInProcess: Bool = false
    @State private var localModelPath: String = ""
    @State private var availableModels: [String] = []
    @State private var availableLanguages: [String] = []
    @State private var disabledModels: [String] = WhisperKit.recommendedModels().disabled
    @State private var isGestureValid: Bool = true
    
    @AppStorage("selectedModel") private var selectedModel: String = WhisperKit.recommendedModels().default
    @AppStorage("selectedTab") private var selectedTab: String = "Transcribe"
    @AppStorage("selectedTask") private var selectedTask: String = "transcribe"
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "english"
    @AppStorage("repoName") private var repoName: String = "argmaxinc/whisperkit-coreml"
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("enableEagerDecoder") private var enableEagerDecoder: Bool = false
    @AppStorage("temperatureStart") private var temperatureStart: Double = 0
    @AppStorage("fallbackCount") private var fallbackCount: Double = 4
    @AppStorage("compressionCheckWindow") private var compressionCheckWindow: Double = 20
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.3
    @AppStorage("useVAD") private var useVAD: Bool = true
    
    @State private var loadingProgressValue: Float = 0.0
    @State private var specializationProgressRatio: Float = 0.7
    @State private var isFilePickerPresented = false
    @State private var firstTokenTime: TimeInterval = 0
    @State private var pipelineStart: TimeInterval = 0
    @State private var realTimeFactor: TimeInterval = 0
    @State private var tokensPerSecond: TimeInterval = 0
    @State private var currentLag: TimeInterval = 0
    @State private var currentFallbacks: Int = 0
    @State private var lastBufferSize: Int = 0
    @State private var lastConfirmedSegmentEndSeconds: Float = 0
    @State private var requiredSegmentsForConfirmation: Int = 2
    @State private var bufferEnergy: [Float] = []
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var confirmedSegments: [TranscriptionSegment] = []
    @State private var unconfirmedSegments: [TranscriptionSegment] = []
    @State private var unconfirmedText: [String] = []
// Add a reference to the CameraView
    @State private var showAdvancedOptions: Bool = false
    @State private var transcriptionTask: Task<Void, Never>? = nil
    
    @State private var selectedCategoryId: MenuItem.ID?
    private var menu = [
        //MenuItem(name: "Transcribe", image: "book.pages"),
        MenuItem(name: "Stream", image: "waveform.badge.mic"),
    ]
    
    
    @State private var base64Image: String? = nil
    
    struct MenuItem: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var image: String
    }
    
    // MARK: Views
    
    func resetState() {
        isRecording = false
        isTranscribing = false
        whisperKit?.audioProcessor.stopRecording()
        currentText = ""
        unconfirmedText = []
        
        firstTokenTime = 0
        pipelineStart = 0
        realTimeFactor = 0
        tokensPerSecond = 0
        currentLag = 0
        currentFallbacks = 0
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        bufferEnergy = []
        confirmedSegments = []
        unconfirmedSegments = []
    }
    
    
    var body: some View {
        
        VStack {
            cameraView
                .frame(height: UIScreen.main.bounds.height*0.75)
            
            Spacer() // Pushes everything above to the top and button to the bottom
            controlsView
                .frame(maxWidth: .infinity, alignment: .top) // Align to top
                Button(action: {
                    // This action will not be called due to the long press gesture
                }) {
                    Text(modelState == .loaded ? (isRequestInProcess ? "Getting the info..." : "Hold to speak") : "Loading model")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .padding(.vertical)
                }
                .cornerRadius(10)
                .padding(.all)
                .disabled(modelState != .loaded || isRequestInProcess)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .local)
                        .onChanged { value in
                            // Detect vertical drag to invalidate the long press
                            if abs(value.translation.height) > 10 {
                                self.isGestureValid = false
                            }
                        }
                )
                .onLongPressGesture(minimumDuration: 1.5, maximumDistance: .infinity, pressing: { pressing in
                    if pressing {
                        // Long press has started
                        self.isGestureValid = true
                        speechSynthesizer.stopSpeaking(at: .immediate)
                        provideUIFeedback(impactType: .medium)
                        //print("RESETING THE SEGMENTS")
                        resetState()
                        isRecording = true
                        startRecording(true)
                    } else {
                        // Long press has ended, check if swipe action was not detected
                        if self.isGestureValid {
                            self.isGestureValid = false
                            provideNotificationFeedback(feedbackType: .success)
                            takePhotoAndPrintBase64()
                        }
                    }
                }, perform: {})

    //         Button(action: {
    //     // This action will not be called due to the long press gesture
    //         }) {
    //             Text(modelState == .loaded ? "Hold to speak" : "Loading model")
    //                 .frame(maxWidth: .infinity, maxHeight: .infinity)
    //                 .font(.title2)
    //                 .foregroundColor(.white)
    //                 .padding(.vertical)
    //         }
            
    //         .cornerRadius(10)
    //         .padding(.all)
    //         .disabled(modelState != .loaded)
    //         .onLongPressGesture(minimumDuration: 1.5, maximumDistance: 10, pressing: { pressing in
    //             if pressing {
    //                  self.isGestureValid = true
    //                 speechSynthesizer.stopSpeaking(at: .immediate)
    //                 provideUIFeedback(impactType: .medium)
    //                 //print("RESETING THE SEGMENTS")
    //                 resetState()
    //                 isRecording = true
    //                 startRecording(true)
                    
                                
                    
    //             }  else{
    //                 if self.isGestureValid {
    //                      self.isGestureValid = false
    //             provideNotificationFeedback(feedbackType: .success)
    //             takePhotoAndPrintBase64()
    //         }
    //             }
    // }, perform: {})
        }// Extend to the bottom edge of the screen
        .background(modelState == .loaded ? Color(hex: 0x668BFF): Color.gray)
         .edgesIgnoringSafeArea(.all)
        .onAppear {
            Task {
            }
            fetchModels()
            // Set the selected model to "tiny"
            selectedModel = "tiny"
            // Load the "tiny" model
            loadModel(selectedModel)
            
            // Preselect the "Stream" category
            if let streamCategory = menu.first(where: { $0.name == "Stream" }) {
                selectedCategoryId = streamCategory.id
            }
        }
    }


func takePhotoAndPrintBase64() {
    // Set up the callback
    model.onPhotoCaptured = { base64String in
        DispatchQueue.main.async {
            // Use the base64String as needed, e.g., assign to a state variable
            self.base64Image = base64String
            
            // Print the base64 string or do something else with it
           // Inside some View body or an event handler like .onAppear
        Task {
            //await getResponse(withImage: base64Image)
            await getResponseWithGemini(withImage: base64String)
        }
            //print("Captured image as base64: \(base64String)")
        }
    }
    
    // Trigger the photo capture
    model.camera.takePhoto()
}

//MARK: - Camera View
var cameraView: some View {
        
        NavigationStack {
            GeometryReader { geometry in
                ViewfinderView(image:  $model.viewfinderImage )
                    .overlay(alignment: .center)  {
                        Color.clear
                            .frame(height: geometry.size.height * (1 - (Self.barHeightFactor * 2)))
                            .accessibilityElement()
                            .accessibilityLabel("View Finder")
                            .accessibilityAddTraits([.isImage])
                    }
                    .background(.black)
            }
            .task {
                await model.camera.start()
               // await model.loadPhotos()
               // await model.loadThumbnail()
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .ignoresSafeArea()
            .statusBar(hidden: true)
        }
    }

     private func buttonsView() -> some View {
        HStack(spacing: 60) {
            
            Spacer()
            
            
            Button {
                model.camera.takePhoto()
            } label: {
                Label {
                    Text("Take Photo")
                } icon: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .frame(width: 62, height: 62)
                        Circle()
                            .fill(.white)
                            .frame(width: 50, height: 50)
                    }
                }
            }
            
        
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding()
    }
    // MARK: - Controls
    
    var controlsView: some View {
        VStack {
            basicSettingsView
            if let selectedCategoryId, let _ = menu.first(where: { $0.id == selectedCategoryId }) {
                VStack {
//                    Button {
//                        withAnimation {
//                            toggleRecording(shouldLoop: true)
//                        }
//                    } label: {
//                        Image(systemName: !isRecording ? "record.circle" : "stop.circle.fill")
//                            .resizable()
//                            .scaledToFit()
//                            .frame(width: 70, height: 70)
//                            .padding()
//                            .foregroundColor(modelState != .loaded ? .gray : .indigo)
//                    }
//                    .contentTransition(.symbolEffect(.replace))
//                    .buttonStyle(BorderlessButtonStyle())
//                    .disabled(modelState != .loaded)
//                    .frame(minWidth: 0, maxWidth: .infinity)
                    
//                    Button {
//                        resetState()
//                    } label: {
//                        Label("Reset", systemImage: "arrow.clockwise")
//                    }
//                    .frame(minWidth: 0, maxWidth: .infinity)
//                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .sheet(isPresented: $showAdvancedOptions, content: {
            advancedSettingsView
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        })
    }
    
    var basicSettingsView: some View {
        VStack {
        }
    }
    
    var advancedSettingsView: some View {
        NavigationView {
            settingsForm
                .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    var settingsForm: some View {
        List {
            HStack {
                Text("Show Timestamps")
                InfoButton("Toggling this will include/exclude timestamps in both the UI and the prefill tokens.\nEither <|notimestamps|> or <|0.00|> will be forced based on this setting unless \"Prompt Prefill\" is de-selected.")
                Spacer()
                Toggle("", isOn: $enableTimestamps)
            }
            //.padding(.horizontal)
            
            HStack {
                Text("Special Characters")
                InfoButton("Toggling this will include/exclude special characters in the transcription text.")
                Spacer()
                Toggle("", isOn: $enableSpecialCharacters)
            }
            // .padding(.horizontal)
            
            HStack {
                Text("Prompt Prefill")
                InfoButton("When Prompt Prefill is on, it will force the task, language, and timestamp tokens in the decoding loop. \nToggle it off if you'd like the model to generate those tokens itself instead.")
                Spacer()
                Toggle("", isOn: $enablePromptPrefill)
            }
            //.padding(.horizontal)
            
            HStack {
                Text("Cache Prefill")
                InfoButton("When Cache Prefill is on, the decoder will try to use a lookup table of pre-computed KV caches instead of computing them during the decoding loop. \nThis allows the model to skip the compute required to force the initial prefill tokens, and can speed up inference")
                Spacer()
                Toggle("", isOn: $enableCachePrefill)
            }
            // .padding(.horizontal)
            
            VStack {
                Text("Starting Temperature:")
                HStack {
                    Slider(value: $temperatureStart, in: 0...1, step: 0.1)
                    Text(temperatureStart.formatted(.number))
                    InfoButton("Controls the initial randomness of the decoding loop token selection.\nA higher temperature will result in more random choices for tokens, and can improve accuracy.")
                }
            }
            // .padding(.horizontal)
            
            VStack {
                Text("Max Fallback Count:")
                HStack {
                    Slider(value: $fallbackCount, in: 0...5, step: 1)
                    Text(fallbackCount.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Controls how many times the decoder will fallback to a higher temperature if any of the decoding thresholds are exceeded.\n Higher values will cause the decoder to run multiple times on the same audio, which can improve accuracy at the cost of speed.")
                }
            }
            // .padding(.horizontal)
            
            VStack {
                Text("Compression Check Tokens")
                HStack {
                    Slider(value: $compressionCheckWindow, in: 0...100, step: 5)
                    Text(compressionCheckWindow.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Amount of tokens to use when checking for whether the model is stuck in a repetition loop.\nRepetition is checked by using zlib compressed size of the text compared to non-compressed value.\n Lower values will catch repetitions sooner, but too low will miss repetition loops of phrases longer than the window.")
                }
            }
            //.padding(.horizontal)
            
            VStack {
                Text("Max Tokens Per Loop")
                HStack {
                    Slider(value: $sampleLength, in: 0...Double(min(whisperKit?.textDecoder.kvCacheMaxSequenceLength ?? WhisperKit.maxTokenContext, WhisperKit.maxTokenContext)), step: 10)
                    Text(sampleLength.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Maximum number of tokens to generate per loop.\nCan be lowered based on the type of speech in order to further prevent repetition loops from going too long.")
                }
            }
            // .padding(.horizontal)
            
            VStack {
                Text("Silence Threshold")
                HStack {
                    Slider(value: $silenceThreshold, in: 0...1, step: 0.05)
                    Text(silenceThreshold.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Relative silence threshold for the audio. \n Baseline is set by the quietest 100ms in the previous 2 seconds.")
                }
            }
            // .padding(.horizontal)
        }
        .navigationTitle("Decoding Options")
        .toolbar(content: {
            ToolbarItem {
                Button {
                    showAdvancedOptions = false
                } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
            }
        })
    }
    
    struct InfoButton: View {
        var infoText: String
        @State private var showInfo = false
        
        init(_ infoText: String) {
            self.infoText = infoText
        }
        
        var body: some View {
            Button(action: {
                self.showInfo = true
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(Color("668BFF"))
            }
            .popover(isPresented: $showInfo) {
                Text(infoText)
                    .padding()
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    // Implement the checkModelStateAndAct method
private func checkModelStateAndAct() {
    if modelState == .loaded {
        // Assuming startRecording takes a Bool parameter indicating whether to loop
        //toggleRecording(shouldLoop: true)
        resetState()
        isRecording = true
        startRecording(true)
        provideNotificationFeedback(feedbackType: .success)
    }
    // You can add more conditions here if there are other actions you want to take based on the modelState
}
    
    // MARK: Logic
   func provideNotificationFeedback(feedbackType: UINotificationFeedbackGenerator.FeedbackType) {
    let feedbackGenerator = UINotificationFeedbackGenerator()
    feedbackGenerator.prepare()
    feedbackGenerator.notificationOccurred(feedbackType)
}
    func provideUIFeedback(impactType: UIImpactFeedbackGenerator.FeedbackStyle) {
        let feedbackGenerator = UIImpactFeedbackGenerator(style: impactType )
       feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
 }
     
    
    func getResponse(withImage base64Image: String?) async {
        isRequestInProcess = true 
        let fullTranscript = formatSegments(confirmedSegments + unconfirmedSegments, withTimestamps: enableTimestamps).joined(separator: "\n")
        print("THIS IS BEING SENT: ", fullTranscript)
        let message = """
    \(fullTranscript)
    -----
    \(self.prompt)
    """
        
        // Prepare the URL and request
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            print("Invalid URL")
             isRequestInProcess = false 
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Replace `your_openai_api_key` with your actual OpenAI API key
        request.addValue("Bearer \(Keys.openAIKey)", forHTTPHeaderField: "Authorization")
        //print(base64Image)
        // Prepare the JSON payload
         let textContent: [String: Any] = [
        "type": "text",
        "text": message
        ]
        
        let imageUrl: [String: Any] = [
            "url": "data:image/jpeg;base64,\(base64Image ?? "")"
        ]
        
        let imageContent: [String: Any] = [
            "type": "image_url",
            "image_url": imageUrl
        ]
        
        let userMessage: [String: Any] = [
            "role": "user",
            "content": [textContent
                        , imageContent
                       ]
        ]
        
        let payload: [String: Any] = [
            "model": "gpt-4-vision-preview",
            "messages": [userMessage],
            "max_tokens": 3000
        ]
        
        do {
            
            // Convert the payload to JSON data
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            
            // Set the request body
            request.httpBody = jsonData
            
            // Perform the request
            let (data, response) = try await URLSession.shared.data(for: request)
            print(response)
            // Check the response and parse the data
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let answers = json["choices"] as? [[String: Any]],
                   let firstAnswer = answers.first,
                   let message = firstAnswer["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    // Update the UI with the API response
                    print(content)
                    //provideTactileFeedback()
                    // Inside getResponse(withImage:) after successfully fetching the content
                    DispatchQueue.main.async {
                       
                        let speechUtterance = AVSpeechUtterance(string: content)
                        speechUtterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
                        speechSynthesizer.speak(speechUtterance)
                    }
                
                    //show tactile feedback
                    
                    // self.provideTactileFeedback(forSuggestion: content)
                    
                    
                }
                
            } else {
                // Handle the error
                print("Error fetching the suggestion: \(response)")
            }
        } catch {
            // Handle the error
            print("Error performing the request: \(error)")
        }
         isRequestInProcess = false
    }
func getResponseWithGemini(withImage base64Image: String?) async {

    let fullTranscript = formatSegments(confirmedSegments + unconfirmedSegments, withTimestamps: enableTimestamps).joined(separator: "\n")
    print("THIS IS BEING SENT: ", fullTranscript)
    let message = """
    \(fullTranscript)
    -----
    \(self.prompt)
    """
    isRequestInProcess = true
    guard let base64Image = base64Image else {
        print("Base64 image string is nil")
        isRequestInProcess = false
        return
    }

    // Define the request URL
    let urlString = "https://us-central1-planar-abbey-418313.cloudfunctions.net/annotate-http/annotate"
    guard let url = URL(string: urlString) else {
        print("Invalid URL")
        isRequestInProcess = false
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    // Replace `your_api_key` with your actual API key
    request.addValue("\(Keys.benvisionKey)", forHTTPHeaderField: "X-API-KEY")

    // Construct the request payload
    let payload: [String: Any] = [
        "image": base64Image,
        "text": message
    ]

    do {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData

        let (data, _) = try await URLSession.shared.data(for: request)

        // Handle the response
        if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] { print(jsonResponse)
            // Assuming the response is a simple JSON string
            print(jsonResponse)
            
            if let responseString = jsonResponse["answer"] as? String {
                print(responseString)
                DispatchQueue.main.async {
                   
                    let speechUtterance = AVSpeechUtterance(string: responseString)
                    speechUtterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                    speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
                    speechSynthesizer.speak(speechUtterance)
                }
                // Use the response string as needed
            }
        }
    } catch {
        print("Error performing the request: \(error)")
    }
    isRequestInProcess = false
}
//    func getResponseWithGemini(withImage base64Image: String?) async {
//    isRequestInProcess = true
//    let fullTranscript = formatSegments(confirmedSegments + unconfirmedSegments, withTimestamps: enableTimestamps).joined(separator: "\n")
//    print("THIS IS BEING SENT: ", fullTranscript)
//    let message = """
//    \(fullTranscript)
//    -----
//    \(self.prompt)
//    """
//    // Adjusted payload based on the provided curl command
//    let payload: [String: Any] = [
//        "contents": [
//            [
//                "role": "user",
//                "parts": [
//                    [
//                        "text": message
//                    ],
//                    [
//                        "inlineData" : [
//                            "mimeType": "image/jpeg",
//                            "data": base64Image ?? ""
//                        ]
//                    ]
//                ]
//            ]
//        ],
//        "generation_config": [
//            "maxOutputTokens": 2048,
//            "temperature": 0.4,
//            "topP": 1,
//            "topK": 32
//        ],
//        "safetySettings": [
//            [
//                "category": "HARM_CATEGORY_HATE_SPEECH",
//                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
//            ],
//            [
//                "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
//                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
//            ],
//            [
//                "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
//                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
//            ],
//            [
//                "category": "HARM_CATEGORY_HARASSMENT",
//                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
//            ]
//        ]
//    ]
//    
//    // Adjusted URL based on the provided curl command
//    let apiEndpoint = "us-central1-aiplatform.googleapis.com"
//    let projectId = "planar-abbey-418313"
//    let modelId = "gemini-1.0-pro-vision-001"
//    let locationId = "us-central1"
//    let urlString = "https://\(apiEndpoint)/v1/projects/\(projectId)/locations/\(locationId)/publishers/google/models/\(modelId):streamGenerateContent"
//    
//    guard let url = URL(string: urlString) else {
//        print("Invalid URL")
//        isRequestInProcess = false
//        return
//    }
//    
//    var request = URLRequest(url: url)
//    request.httpMethod = "POST"
//    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
//    // Note: You need to replace the authorization header with a valid method to obtain the Bearer token
//    request.addValue("Bearer \(Keys.GCPAccessToken)", forHTTPHeaderField: "Authorization")
//    
//    do {
//        let jsonData = try JSONSerialization.data(withJSONObject: payload)
//        request.httpBody = jsonData
//        
//        let (data, response) = try await URLSession.shared.data(for: request)
//        print(response)
//        
//        // Handle the response
//        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
//            // Parse the response data
//            print("Success: \(data)")
//        } else {
//            print("Error fetching the suggestion: \(response)")
//        }
//    } catch {
//        print("Error performing the request: \(error)")
//    }
//    isRequestInProcess = false
//}

    func fetchModels() {
        availableModels = [selectedModel]
        
        // First check what's already downloaded
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = documents.appendingPathComponent(modelStorage).path
            
            // Check if the directory exists
            if FileManager.default.fileExists(atPath: modelPath) {
                localModelPath = modelPath
                do {
                    let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                    for model in downloadedModels where !localModels.contains(model) && model.starts(with: "openai") {
                        localModels.append(model)
                    }
                } catch {
                    print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
                }
            }
        }
        
        localModels = WhisperKit.formatModelFiles(localModels)
        for model in localModels {
            if !availableModels.contains(model),
               !disabledModels.contains(model)
            {
                availableModels.append(model)
            }
        }
        
        print("Found locally: \(localModels)")
        print("Previously selected model: \(selectedModel)")
        
        Task {
            let remoteModels = try await WhisperKit.fetchAvailableModels(from: repoName)
            for model in remoteModels {
                if !availableModels.contains(model),
                   !disabledModels.contains(model)
                {
                    availableModels.append(model)
                }
            }
        }
    }
    
    func loadModel(_ model: String, redownload: Bool = false) {
        print("Selected Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "nil")")

        whisperKit = nil
        Task {
            whisperKit = try await WhisperKit(
                verbose: true,
                logLevel: .info,
                prewarm: false,
                load: false,
                download: false
            )
            guard let whisperKit = whisperKit else {
                return
            }

            var folder: URL?

            // Check if the model is available locally
            if localModels.contains(model) && !redownload {
                // Get local model folder URL from localModels
                // TODO: Make this configurable in the UI
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent("openai_whisper-\(model)")
            } else {
                // Download the model
                folder = try await WhisperKit.download(variant: model, from: repoName, progressCallback: { progress in
                    DispatchQueue.main.async {
                        loadingProgressValue = Float(progress.fractionCompleted) * specializationProgressRatio
                        modelState = .downloading
                    }
                })
            }

            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder

                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio
                    modelState = .prewarming
                }
                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                    modelState = .loading
                }

                try await whisperKit.loadModels()

                await MainActor.run {
                    availableLanguages = whisperKit.tokenizer?.langauges.map { $0.key }.sorted() ?? ["english"]
                    loadingProgressValue = 1.0
                    modelState = whisperKit.modelState
                    checkModelStateAndAct()
                }
            }
        }
    }


func selectFile() {
    isFilePickerPresented = true
}

func handleFilePicker(result: Result<[URL], Error>) {
    switch result {
    case let .success(urls):
        guard let selectedFileURL = urls.first else { return }
        if selectedFileURL.startAccessingSecurityScopedResource() {
            do {
                // Access the document data from the file URL
                let audioFileData = try Data(contentsOf: selectedFileURL)
                
                // Create a unique file name to avoid overwriting any existing files
                let uniqueFileName = UUID().uuidString + "." + selectedFileURL.pathExtension
                
                // Construct the temporary file URL in the app's temp directory
                let tempDirectoryURL = FileManager.default.temporaryDirectory
                let localFileURL = tempDirectoryURL.appendingPathComponent(uniqueFileName)
                
                // Write the data to the temp directory
                try audioFileData.write(to: localFileURL)
                
                print("File saved to temporary directory: \(localFileURL)")
                
                transcribeFile(path: selectedFileURL.path)
            } catch {
                print("File selection error: \(error.localizedDescription)")
            }
        }
    case let .failure(error):
        print("File selection error: \(error.localizedDescription)")
    }
}

func transcribeFile(path: String) {
    resetState()
    whisperKit?.audioProcessor = AudioProcessor()
    Task {
        do {
            try await transcribeCurrentFile(path: path)
        } catch {
            print("File selection error: \(error.localizedDescription)")
        }
    }
}

func toggleRecording(shouldLoop: Bool) {
    isRecording.toggle()
    
    if isRecording {
        resetState()
        startRecording(shouldLoop)
    } else {
        stopRecording(shouldLoop)
    }
}

func startRecording(_ loop: Bool) {
    
    
    if let audioProcessor = whisperKit?.audioProcessor {
        Task(priority: .userInitiated) {
            guard await AudioProcessor.requestRecordPermission() else {
                print("Microphone access was not granted.")
                return
            }
            
            try? audioProcessor.startRecordingLive { _ in
                DispatchQueue.main.async {
                    
                    bufferEnergy = whisperKit?.audioProcessor.relativeEnergy ?? []
                }
            }
            
            // Delay the timer start by 1 second
            isRecording = true
            isTranscribing = true
            if loop {
                realtimeLoop()
            }
        }
    }
}

func stopRecording(_ loop: Bool) {
    isRecording = false
    stopRealtimeTranscription()
    if let audioProcessor = whisperKit?.audioProcessor {
        audioProcessor.stopRecording()
    }
    
    // If not looping, transcribe the full buffer
    if !loop {
        Task {
            do {
                try await transcribeCurrentBuffer()
                
            } catch {
                print("Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: Transcribe Logic

func transcribeCurrentFile(path: String) async throws {
    guard let audioFileBuffer = AudioProcessor.loadAudio(fromPath: path) else {
        return
    }
    
    let audioFileSamples = AudioProcessor.convertBufferToArray(buffer: audioFileBuffer)
    let transcription = try await transcribeAudioSamples(audioFileSamples)
    
    await MainActor.run {
        currentText = ""
        unconfirmedText = []
        guard let segments = transcription?.segments else {
            return
        }
        
        self.tokensPerSecond = transcription?.timings?.tokensPerSecond ?? 0
        self.realTimeFactor = transcription?.timings?.realTimeFactor ?? 0
        self.firstTokenTime = transcription?.timings?.firstTokenTime ?? 0
        self.pipelineStart = transcription?.timings?.pipelineStart ?? 0
        self.currentLag = transcription?.timings?.decodingLoop ?? 0
        
        self.confirmedSegments = segments
    }
}

func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
    guard let whisperKit = whisperKit else { return nil }
    
    let languageCode = whisperKit.tokenizer?.langauges[selectedLanguage] ?? "en"
    let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
    let seekClip = [lastConfirmedSegmentEndSeconds]
    
    let options = DecodingOptions(
        verbose: false,
        task: task,
        language: languageCode,
        temperatureFallbackCount: 3, // limit fallbacks for realtime
        sampleLength: Int(sampleLength), // reduced sample length for realtime
        usePrefillPrompt: enablePromptPrefill,
        usePrefillCache: enableCachePrefill,
        skipSpecialTokens: !enableSpecialCharacters,
        withoutTimestamps: !enableTimestamps,
        clipTimestamps: seekClip
    )
    
    // Early stopping checks
    let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
        DispatchQueue.main.async {
            let fallbacks = Int(progress.timings.totalDecodingFallbacks)
            if progress.text.count < currentText.count {
                if fallbacks == self.currentFallbacks {
                    self.unconfirmedText.append(currentText)
                } else {
                    print("Fallback occured: \(fallbacks)")
                }
            }
            self.currentText = progress.text
            self.currentFallbacks = fallbacks
        }
        // Check early stopping
        let currentTokens = progress.tokens
        let checkWindow = Int(compressionCheckWindow)
        if currentTokens.count > checkWindow {
            let checkTokens: [Int] = currentTokens.suffix(checkWindow)
            let compressionRatio = compressionRatio(of: checkTokens)
            if compressionRatio > options.compressionRatioThreshold! {
                return false
            }
        }
        if progress.avgLogprob! < options.logProbThreshold! {
            return false
        }
        
        return nil
    }
    
    let transcription = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options, callback: decodingCallback)
    return transcription
}

// MARK: Streaming Logic

func realtimeLoop() {
    transcriptionTask = Task {
        while isRecording && isTranscribing {
            do {
                try await transcribeCurrentBuffer()
            } catch {
                print("Error: \(error.localizedDescription)")
                break
            }
        }
    }
}

func stopRealtimeTranscription() {
    isTranscribing = false
    transcriptionTask?.cancel()
}

func transcribeCurrentBuffer() async throws {
    guard let whisperKit = whisperKit else { return }
    
    // Retrieve the current audio buffer from the audio processor
    let currentBuffer = whisperKit.audioProcessor.audioSamples
    
    // Calculate the size and duration of the next buffer segment
    let nextBufferSize = currentBuffer.count - lastBufferSize
    let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
    
    // Only run the transcribe if the next buffer has at least 1 second of audio
    guard nextBufferSeconds > 1 else {
        await MainActor.run {
            if currentText == "" {
                currentText = "Waiting for speech..."
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
        return
    }
    
    if useVAD {
        // Retrieve the current relative energy values from the audio processor
        let currentRelativeEnergy = whisperKit.audioProcessor.relativeEnergy
        
        // Calculate the number of energy values to consider based on the duration of the next buffer
        // Each energy value corresponds to 1 buffer length (100ms of audio), hence we divide by 0.1
        let energyValuesToConsider = Int(nextBufferSeconds / 0.1)
        
        // Extract the relevant portion of energy values from the currentRelativeEnergy array
        let nextBufferEnergies = currentRelativeEnergy.suffix(energyValuesToConsider)
        
        // Determine the number of energy values to check for voice presence
        // Considering up to the last 1 second of audio, which translates to 10 energy values
        let numberOfValuesToCheck = max(10, nextBufferEnergies.count - 10)
        
        // Check if any of the energy values in the considered range exceed the silence threshold
        // This indicates the presence of voice in the buffer
        let voiceDetected = nextBufferEnergies.prefix(numberOfValuesToCheck).contains { $0 > Float(silenceThreshold) }
        
        // Only run the transcribe if the next buffer has voice
        guard voiceDetected else {
            await MainActor.run {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
            }
            
            //                if nextBufferSeconds > 30 {
            //                    // This is a completely silent segment of 30s, so we can purge the audio and confirm anything pending
            //                    lastConfirmedSegmentEndSeconds = 0
            //                    whisperKit.audioProcessor.purgeAudioSamples(keepingLast: 2 * WhisperKit.sampleRate) // keep last 2s to include VAD overlap
            //                    currentBuffer = whisperKit.audioProcessor.audioSamples
            //                    lastBufferSize = 0
            //                    confirmedSegments.append(contentsOf: unconfirmedSegments)
            //                    unconfirmedSegments = []
            //                }
            
            // Sleep for 100ms and check the next buffer
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
    }
    
    // Run transcribe
    lastBufferSize = currentBuffer.count
    
    let transcription = try await transcribeAudioSamples(Array(currentBuffer))
    
    // We need to run this next part on the main thread
    await MainActor.run {
        currentText = ""
        unconfirmedText = []
        guard let segments = transcription?.segments else {
            return
        }
        
        self.tokensPerSecond = transcription?.timings?.tokensPerSecond ?? 0
        self.realTimeFactor = transcription?.timings?.realTimeFactor ?? 0
        self.firstTokenTime = transcription?.timings?.firstTokenTime ?? 0
        self.pipelineStart = transcription?.timings?.pipelineStart ?? 0
        self.currentLag = transcription?.timings?.decodingLoop ?? 0
        
        // Logic for moving segments to confirmedSegments
        if segments.count > requiredSegmentsForConfirmation {
            // Calculate the number of segments to confirm
            let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation
            
            // Confirm the required number of segments
            let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
            let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))
            
            // Update lastConfirmedSegmentEnd based on the last confirmed segment
            if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                
                // Add confirmed segments to the confirmedSegments array
                if !self.confirmedSegments.contains(confirmedSegmentsArray) {
                    self.confirmedSegments.append(contentsOf: confirmedSegmentsArray)
                }
            }
            
            // Update transcriptions to reflect the remaining segments
            self.unconfirmedSegments = remainingSegments
        } else {
            // Handle the case where segments are fewer or equal to required
            self.unconfirmedSegments = segments
        }
    }
}

}
#Preview{
    ContentView()
#if os(macOS)
        .frame(width: 800, height: 500)
#endif
}

