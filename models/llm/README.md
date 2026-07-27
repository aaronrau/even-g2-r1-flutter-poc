# On-device LLM models

Gemma 4 E4B is stored as four Git LFS chunks so the complete Android
installation can be reproduced without downloading model weights from an
unversioned source during installation.

Materialize the chunks after cloning:

```sh
git lfs pull --include='models/llm/**'
```

`tool/install_android_workbench.sh` installs the APK and streams the chunks
directly into the app-private
`files/workbench/models/gemma-4-e4b-it/gemma-4-E4B-it.litertlm` path. The
installer validates the combined SHA-256 before copying and validates the
reconstructed file again on the phone. It uses Android `run-as`; phone root is
neither used nor required.

Model source:
<https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm>

Gemma 4 is distributed under the Apache License 2.0. See
`LICENSE.apache-2.0`.
