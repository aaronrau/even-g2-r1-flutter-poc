import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

typedef PackageInfoLoader = Future<PackageInfo> Function();

final class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({this.loadPackageInfo, super.key});

  final PackageInfoLoader? loadPackageInfo;

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

final class _AppVersionLabelState extends State<AppVersionLabel> {
  String? _version;
  String? _buildNumber;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPackageInfo());
  }

  Future<void> _loadPackageInfo() async {
    try {
      final packageInfo =
          await (widget.loadPackageInfo ?? PackageInfo.fromPlatform)();
      if (!mounted) {
        return;
      }
      setState(() {
        _version = packageInfo.version;
        _buildNumber = packageInfo.buildNumber;
      });
    } catch (_) {
      // Package metadata is informational and must not affect app startup.
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = _version;
    final buildNumber = _buildNumber;
    if (version == null || buildNumber == null) {
      return const SizedBox.shrink();
    }
    final visibleLabel = 'v$version b$buildNumber';
    return Semantics(
      label: 'App version $version, build $buildNumber',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          visibleLabel,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
