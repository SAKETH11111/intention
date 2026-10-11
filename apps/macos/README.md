# Intention for Mac

Intention is a native macOS dictation and email demo. It never sends mail.

Build with `bash scripts/mac-build.sh`. Render synthetic setup screenshots with `bash scripts/mac-render.sh /tmp/intention-evidence/after`.

The build reads `INTENTION_PROXY_URL` from the gitignored `apps/macos/Config/Local.xcconfig`. With no value, sign-in and speech are unavailable. HTTPS proxy origins and HTTP localhost or 127.0.0.1 with an explicit port are accepted. Speech uses the same origin at `/speech` with WSS or loopback WS. No backend credentials are compiled into the app.

Live mailbox connection, automatic updates, diagnostic uploads and interaction archives are disabled. Use a demo invite for an account containing synthetic messages. Permission and insertion checks require separate live acceptance on the demo app.
