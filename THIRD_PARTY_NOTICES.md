# Third-party notices

## MentraOS

G2 and R1 protocol details in this project were ported from
[MentraOS](https://github.com/Mentra-Community/MentraOS).

MIT License

Copyright (c) 2026 Mentra Labs, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Google liblc3

The Android LC3 decoder vendors source from
[google/liblc3](https://github.com/google/liblc3).

Copyright 2022 Google LLC. Licensed under the Apache License, Version 2.0.
The vendored files retain their upstream license headers.

## Sherpa-ONNX and speech models

Local VAD and speech recognition use
[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), licensed under the
Apache License, Version 2.0. Large Silero VAD and Whisper model artifacts are
downloaded separately from the official Sherpa-ONNX model release and are not
committed to this repository.

The Android arm64 package contains a pinned, patched Sherpa-ONNX `v1.13.4`
native runtime. The patch enables the NNAPI execution-provider registration
path and disables NNAPI's reference-CPU device. The Apache-2.0 license is
included beside the vendored package.

Sherpa-ONNX dynamically links
[ONNX Runtime](https://github.com/microsoft/onnxruntime) `1.27.0`, licensed
under the MIT License. Its license is included beside the vendored package.
