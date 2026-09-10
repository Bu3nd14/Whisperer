# Whisperer

iOS proof of concept that transcribes multilingual audio segments with `gpt-transcribe` and translates them into English with `gpt-4.1-mini`.

## Run on iPhone

1. Open `Whisperer.xcodeproj` in Xcode.
2. Select the `Whisperer` target and configure your team under Signing & Capabilities.
3. Select your iPhone as the destination and run the app.
4. Open the **Settings** tab, enter your OpenAI API key, and tap **Save to Keychain**.
5. Return to the **Translation** tab, tap **Start translation**, grant microphone access, and wait for the **API connected** indicator.
6. Speak in one or more languages. The English translation will appear progressively.
7. Tap **Stop translation** to end the session and receive the final deltas.

The proof of concept sends 24 kHz mono PCM16 audio to the Realtime Transcription API with `5x` gain and `far_field` noise reduction, making it suitable for conversations and audio sources in the room. Logs record the original level, transmitted level, and clipping separately. Local VAD evaluates the transmitted signal using an RMS threshold of `0.004` to start and `0.002` to continue. A segment is finalized after approximately 600 ms of silence or 6 seconds of buffered audio, while inactive buffers are cleared every 2 seconds. Segments are translated concurrently through the Responses API and displayed in their original order. The source language is detected automatically and the target language is English. The API key is not included in the source code and is stored in the device Keychain.

## Security

Using a permanent API key directly from a mobile app is acceptable only for this personal proof of concept. Before distributing the app, add a backend that creates short-lived tokens through `POST /v1/realtime/client_secrets` and authenticate the client with those ephemeral tokens.
