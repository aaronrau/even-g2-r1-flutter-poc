# Parakeet STT model assets

The quantized ONNX weights in this directory are stored with Git LFS and are
copied to an installed Android app by `tool/stage_android_stt_model.sh`. They
are deliberately not packaged in the APK.

After cloning, materialize and verify them with:

```sh
git lfs install
git lfs pull --include='models/stt/**'
(cd models/stt && sha256sum --check SHA256SUMS)
```

An ONNX file that starts with
`version https://git-lfs.github.com/spec/v1` is only an unresolved LFS pointer.

## Attribution and license

- `parakeet-0.6b` is derived from NVIDIA's
  [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
- `parakeet-110m` is derived from NVIDIA and Suno's
  [Parakeet TDT-CTC 110M](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m).
- The Android-ready INT8 ONNX conversions are distributed through the
  [sherpa-onnx ASR model releases](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models).

Both original model cards license the models under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The files retained
here are the Sherpa-ONNX conversions without further binary modification.
Their filenames and SHA-256 values are pinned in `SHA256SUMS`.
