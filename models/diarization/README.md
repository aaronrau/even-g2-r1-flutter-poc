# Speaker diarization model assets

These pinned ONNX files are stored with Git LFS and copied into an installed
Android app by `tool/stage_android_diarization_models.sh`. They are not
packaged in the APK.

After cloning, materialize and verify them with:

```sh
git lfs install
git lfs pull --include='models/diarization/**'
(cd models/diarization && sha256sum --check SHA256SUMS)
```

An ONNX file that starts with
`version https://git-lfs.github.com/spec/v1` is only an unresolved LFS pointer.

## Attribution and license

- `segmentation.int8.onnx` is the Sherpa-ONNX INT8 conversion of
  [pyannote segmentation 3.0](https://huggingface.co/pyannote/segmentation-3.0).
  It is licensed under MIT; the retained notice is
  `LICENSE.pyannote-mit`.
- `nemo_en_titanet_small.onnx` is the Sherpa-ONNX export of NVIDIA NeMo
  [TitaNet Small](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small).
  NeMo is licensed under Apache 2.0; the license is
  `LICENSE.nemo-apache-2.0`.

The files are retained without further binary modification. Their filenames
and SHA-256 values are pinned in `SHA256SUMS`.
