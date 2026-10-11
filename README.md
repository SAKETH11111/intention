# Intention

Intention turns what you say into writing in your own voice, inside the Mac apps you already use. Hold a key, speak, and get the finished text at your cursor.

## How it works

The native Mac app records while you hold your dictation key. Streaming speech recognition turns your words into text, a writer learns your style from your own writing, and the app inserts the result at the cursor. A local proxy connects the client to privately configured speech and writing services.

## Run locally

On macOS 14 or later with Xcode command-line tools installed, build the app from the repository root.

```sh
bash scripts/mac-build.sh
```

Grant the app microphone and Accessibility permission. Set `INTENTION_PROXY_URL` in the ignored `apps/macos/Config/Local.xcconfig` to your local proxy origin.

With Node.js 22 or later, copy `proxy/.env.example` to an ignored root `.env`, configure your own upstream services, then run the proxy. The example has empty upstream values; service credentials are not included.

```sh
npm --prefix proxy ci
npm --prefix proxy start
```

Run the static site with Python 3.

```sh
python3 -m http.server 4321 --directory site
```

The video project uses React and Remotion. Install its dependencies with `npm --prefix video ci`.

## Tools used

Swift, SwiftUI, AppKit, Node.js, WebSockets, React, Remotion, Python, Vercel, Claude Opus and GPT-6.1-Sol.

## License

[MIT](LICENSE). Third-party assets and dependencies retain their own license notices.
