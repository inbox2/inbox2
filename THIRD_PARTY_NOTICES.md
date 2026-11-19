# Third-party notices

Code and assets in this repository that were written by others, with their
licenses. Dependencies pulled in by a package manager (Cargo, npm/yarn,
Bundler, Go modules, Gradle, SwiftPM, pip) carry their own license files and
are not repeated here.

## Code

| Path | Project | License |
|------|---------|---------|
| `ui/ios/Vendor/swift/SherpaOnnx.swift`, `SherpaOnnx-Bridging-Header.h` | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Copyright (c) 2023 Xiaomi Corporation | Apache-2.0 |

The sherpa-onnx xcframeworks the iOS app links are downloaded by
`bin/fetch-sherpa-onnx` and are not stored in the repository.

## Fonts

All bundled fonts are licensed under the SIL Open Font License 1.1. The
license texts are in `ui/web/public/fonts/OFL-*.txt` (also in
`ui/ios/Resources`; Android's `res/font` cannot hold text files).

| Font | Copyright | Where |
|------|-----------|-------|
| Figtree | The Figtree Project Authors | `ui/web/public/fonts`, `ui/ios/Resources`, `ui/android/app/src/main/res/font` |
| Jost | The Jost Project Authors | same |
| Bodoni Moda | The Bodoni Moda Project Authors | same |
| Rubik | The Rubik Project Authors | same |
| Terminal Grotesque | Raphaël Bastide (Velvetyne) | `ui/web/public/fonts` |
