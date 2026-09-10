//
//  ContentView.swift
//  Whisperer
//
//  Created by Roberto on 10.09.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var transcriber = RealtimeTranscriber()
    @State private var apiKey = KeychainStore.loadAPIKey()
    @State private var keyStatus: String?

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        transcriptCard
                    }
                    .padding(20)
                }
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    recordButton
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
                .navigationTitle("Whisperer")
            }
            .tabItem {
                Label("Translation", systemImage: "captions.bubble")
            }

            settingsTab
                .tabItem {
                    Label("Settings", systemImage: "key")
                }
        }
        .alert("Translation unavailable", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transcriber.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(transcriber.status, systemImage: transcriber.isRecording ? "waveform" : "circle.fill")
                .font(.headline)
                .foregroundStyle(transcriber.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: transcriber.isRecording)
            Text("Live multilingual transcription and English translation for short segments.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label(
                    transcriber.isAPIConnected ? "API connected" : "API disconnected",
                    systemImage: transcriber.isAPIConnected ? "checkmark.circle.fill" : "circle.dashed"
                )
                Label(
                    transcriber.audioSecondsSent.formatted(.number.precision(.fractionLength(1))) + " s of audio",
                    systemImage: "arrow.up.circle"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: transcriber.microphoneLevel)
                .tint(transcriber.microphoneLevel > 0.08 ? .green : .secondary)
                .accessibilityLabel("Microphone level")
            Text("Debug: Documents/\(transcriber.debugLogName)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            Form {
                Section("OpenAI API key") {
                    SecureField("sk-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save to Keychain") {
                        do {
                            try KeychainStore.saveAPIKey(apiKey)
                            keyStatus = apiKey.isEmpty ? "Key removed" : "Key saved"
                        } catch {
                            keyStatus = error.localizedDescription
                        }
                    }

                    if let keyStatus {
                        Text(keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Security") {
                    Text("Proof of concept only: the key remains in the Keychain but is used directly by the client. Do not distribute this build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Debug") {
                    Text("Documents/\(transcriber.debugLogName)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Settings")
            .disabled(transcriber.isRecording || transcriber.isBusy)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Original text")
                    .font(.headline)
                Spacer()
                Button("Clear") { transcriber.clearTranscript() }
                    .font(.subheadline)
                    .disabled(
                        (transcriber.displayedTranscript.isEmpty && transcriber.sourceTranscript.isEmpty)
                        || transcriber.isRecording
                    )
            }

            scrollingTranscript(
                transcriber.displayedSourceTranscript,
                placeholder: "Recognized speech will appear here.",
                anchor: .source,
                height: 120,
                foreground: .secondary
            )

            Divider()

            HStack {
                Text("English translation")
                    .font(.headline)
                Spacer()
                if transcriber.pendingTranslations > 0 {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if transcriber.hasReceivedTranslation {
                    Label("Updated", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            scrollingTranscript(
                transcriber.displayedTranscript,
                placeholder: "The English translation will appear here as you speak.",
                anchor: .translation,
                height: 180,
                foreground: .primary
            )
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func scrollingTranscript(
        _ text: String,
        placeholder: String,
        anchor: TranscriptAnchor,
        height: CGFloat,
        foreground: Color
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.55) : foreground)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                    .textSelection(.enabled)
                    .id(anchor)
            }
            .frame(height: height)
            .onChange(of: text) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        }
    }

    private var recordButton: some View {
        Button {
            if transcriber.isRecording {
                transcriber.stop()
            } else {
                Task { await transcriber.start(apiKey: apiKey) }
            }
        } label: {
            Label(
                transcriber.isRecording ? "Stop translation" : "Start translation",
                systemImage: transcriber.isRecording ? "stop.fill" : "mic.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(transcriber.isRecording ? .red : .accentColor)
        .disabled(transcriber.isBusy)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { transcriber.errorMessage != nil },
            set: { isPresented in
                if !isPresented { transcriber.dismissError() }
            }
        )
    }
}

private enum TranscriptAnchor: Hashable {
    case source
    case translation
}

#Preview {
    ContentView()
}
