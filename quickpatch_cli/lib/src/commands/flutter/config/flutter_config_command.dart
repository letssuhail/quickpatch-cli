import 'dart:async';

import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// {@template flutter_config_command}
/// `quickpatch flutter config`
/// Manage your QuickPatch Flutter Config.
/// {@endtemplate}
class FlutterConfigCommand extends ShorebirdProxyCommand {
  @override
  String get description =>
      '''Configure Flutter settings. This proxies to the underlying `flutter config` command.''';

  @override
  String get name => 'config';

  @override
  FutureOr<int> run() => process.stream('flutter', ['config', ...results.rest]);
}
