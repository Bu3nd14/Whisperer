# Whisperer

POC iOS per trascrivere segmenti audio multilingua con `gpt-transcribe` e tradurli in inglese con `gpt-4.1-mini`.

## Prova su iPhone

1. Apri `Whisperer.xcodeproj` con Xcode.
2. Seleziona il target `Whisperer` e verifica il tuo team in Signing & Capabilities.
3. Seleziona il tuo iPhone come destinazione e avvia l'app.
4. Apri il tab **Impostazioni**, inserisci la chiave OpenAI e premi **Salva nel Keychain**.
5. Torna al tab **Traduzione**, premi **Avvia traduzione**, autorizza il microfono e attendi l'indicatore **API connessa**.
6. Parla in una o più lingue: la traduzione inglese apparirà progressivamente.
7. Premi **Termina traduzione** per terminare la sessione e ricevere gli ultimi delta.

La POC invia PCM16 mono a 24 kHz alla Realtime Transcription API con un guadagno `5x` e riduzione del rumore `far_field`, adatta a conversazioni e sorgenti nella stanza. Il log registra separatamente livello originale, livello trasmesso e clipping. Il VAD locale valuta il segnale trasmesso con una soglia RMS di `0.004` per iniziare e `0.002` per continuare; circa 600 ms di silenzio o 6 secondi di audio buffered finalizzano un segmento, mentre il buffer inattivo viene svuotato ogni 2 secondi. I segmenti vengono tradotti in parallelo tramite la Responses API e mostrati nell'ordine originale. La lingua sorgente viene riconosciuta automaticamente e la destinazione è inglese. La chiave non è inclusa nei sorgenti e viene salvata nel Keychain del dispositivo.

## Sicurezza

L'uso diretto di una API key permanente da un'app mobile è accettabile solo per questa prova personale. Prima di distribuire l'app, aggiungi un backend che crei token brevi tramite `POST /v1/realtime/client_secrets` e fai autenticare il client con quei token effimeri.
