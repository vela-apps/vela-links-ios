# Security

## Reporting a problem
Please email **info@velaapps.in** with the subject "Vela Links SDK security". Include what you found, the SDK version, and steps to
reproduce it. Do not open a public issue for a security problem. We will reply within 3 working days.

## What the SDK is designed to protect
- The SDK key is sent only to the service address you configure, over https (plain http is accepted only for `localhost`,
  `127.0.0.1` and `10.0.2.2`, for development), and is never written to logs, errors or storage.
- Redirects are never followed, so the key cannot be sent on to another host. Answers are capped at 1 MB and every call has a time
  limit.
- Only a Vela Links token (`vlink:` followed by letters and digits) is ever taken from the clipboard; other content never leaves
  the device.
- Links and answers from the service are treated as untrusted data and validated before use.
- The SDK has no third-party dependencies and requests no advertising or device identifiers.

## Supported versions
The latest release receives security fixes.
