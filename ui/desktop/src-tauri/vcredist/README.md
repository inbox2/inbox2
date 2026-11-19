# Visual C++ runtime, app-local

The five x64 DLLs in `x64/` are the Microsoft Visual C++ 2015-2022 runtime, taken
unchanged from `vc_redist.x64.exe` (https://aka.ms/vs/17/release/vc_redist.x64.exe,
downloaded 2026-11-07; the "Minimum Runtime" MSI inside it). `tauri.windows.conf.json`
puts them next to `Inbox2.exe`.

The exe imports `MSVCP140.dll` through the prebuilt ONNX Runtime static libraries, and
a clean Windows install has no VC++ runtime: without these files the app exits at once
with `0xC0000135` and writes no log. App-local DLLs win the search order, so a machine
that does have the redistributable installed keeps working too. Microsoft's redistribution
terms allow shipping these files with an application. See `docs/Desktop-Release.md`.
