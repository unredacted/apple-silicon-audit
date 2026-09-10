# tvOS QR export round trip (simulator)

Date: 2026-09-10. Apple TV 4K (3rd generation) simulator, tvOS 26.5 SDK, Xcode 26.6, host Mac17,7 on 25G83.
Simulators run the host kernel, so the payload describes the Mac and carries `is_simulator: true`.

Steps and results:

1. `Scripts/run-simulator.sh tvOS -initialSelection __export__` built, installed and launched the app on the
   Export screen.
2. `xcrun simctl io <udid> screenshot tv-export.png` captured the 3840×2160 frame.
3. A Vision `VNDetectBarcodesRequest` over the screenshot decoded one QR payload of 3,027 characters
   (171×171 modules, error-correction level M).
4. `silicon-audit import tv-qr.b45` produced compact JSON: `variant: compact`, `device.identity: Mac17,7`,
   `environment.platform: tvOS`, `os_build: 25G83`, `is_simulator: true`, 51 facts.
5. `Scripts/validate-export.sh` reported the JSON valid against `Schema/export-v1.schema.json`.

Capacity probe with `CIQRCodeGenerator` on the host: the largest Base45 string that encodes at level L is
4,297 characters (and 3,392 at level M), one more than the standard's alphanumeric-mode table (4,296 /
3,391) at both levels. This confirms the generator does not fall back to byte mode (2,953) for this
alphabet, and that past the limit it returns nil rather than truncating; the app shows "too large for a
QR code" in that case. Nothing depends on the exact figure: `ExportTests` keeps payloads under 3,300.

Earlier attempt: with the Export screen laid out as a wide two-column row, the tvOS floating sidebar
covered the left third of the code and the decoder found nothing. The screen is a centered column now.
