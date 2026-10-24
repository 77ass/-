# LanBridge protocol (prototype)

- Discovery: UDP broadcast to `255.255.255.255:37654` every 3 seconds.
- Discovery payload: JSON `{service:"lanbridge/1", id, name, port:8765}`.
- Transfer: HTTP `POST /upload?name=<URL-encoded-filename>` to the peer's advertised port.
- Request body: raw file bytes. Receiver asks for approval, then writes into the app documents directory.

This protocol is a prototype, not security-hardened. Do not expose the receiver to untrusted networks. Add authentication and encryption before production use.
