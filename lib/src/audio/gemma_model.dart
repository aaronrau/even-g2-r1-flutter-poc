import 'dart:io';

import 'package:path_provider/path_provider.dart';

final class GemmaModelDefinition {
  const GemmaModelDefinition({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.sha256,
    required this.byteLength,
    required this.downloadUrl,
  });

  final String id;
  final String displayName;
  final String fileName;
  final String sha256;
  final int byteLength;
  final String downloadUrl;
}

const gemma4E4bModel = GemmaModelDefinition(
  id: 'gemma-4-e4b-it',
  displayName: 'Gemma 4 E4B',
  fileName: 'gemma-4-E4B-it.litertlm',
  sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
  byteLength: 3659530240,
  downloadUrl:
      'https://huggingface.co/litert-community/'
      'gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
);

final class GemmaModelStore {
  GemmaModelStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<String?> installedModelPath({
    GemmaModelDefinition model = gemma4E4bModel,
  }) async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/workbench/models/${model.id}');
    final file = File('${directory.path}/${model.fileName}');
    final marker = File('${file.path}.verified');
    if (!await file.exists() ||
        await file.length() != model.byteLength ||
        !await marker.exists() ||
        (await marker.readAsString()).trim() != model.sha256) {
      return null;
    }
    return file.path;
  }
}
