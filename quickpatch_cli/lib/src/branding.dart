import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/version.dart';

/// QuickPatch CLI branding — the ASCII wordmark + welcome banner.
///
/// All color is applied through mason_logger's [AnsiCode.wrap], which strips
/// the escape codes automatically when stdout isn't a TTY (pipes, CI, files),
/// so the art degrades to clean plain text. Callers must still avoid printing
/// the banner in `--json` mode.
abstract class Branding {
  /// "QUICK" in ANSI-Shadow block letters (6 rows).
  static const List<String> _quick = [
    r' ██████╗ ██╗   ██╗██╗ ██████╗██╗  ██╗',
    r'██╔═══██╗██║   ██║██║██╔════╝██║ ██╔╝',
    r'██║   ██║██║   ██║██║██║     █████╔╝ ',
    r'██║▄▄ ██║██║   ██║██║██║     ██╔═██╗ ',
    r'╚██████╔╝╚██████╔╝██║╚██████╗██║  ██╗',
    r' ╚══▀▀═╝  ╚═════╝ ╚═╝ ╚═════╝╚═╝  ╚═╝',
  ];

  /// "PATCH" in ANSI-Shadow block letters (6 rows).
  static const List<String> _patch = [
    r'██████╗  █████╗ ████████╗ ██████╗██╗  ██╗',
    r'██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██║  ██║',
    r'██████╔╝███████║   ██║   ██║     ███████║',
    r'██╔═══╝ ██╔══██║   ██║   ██║     ██╔══██║',
    r'██║     ██║  ██║   ██║   ╚██████╗██║  ██║',
    r'╚═╝     ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝',
  ];

  static const String _tagline = 'Over-the-air updates for Flutter';

  static String _bold(AnsiCode color, String s) =>
      styleBold.wrap(color.wrap(s)) ?? s;

  /// The full two-tone emerald logo (QUICK over PATCH).
  static String logo() {
    final buffer = StringBuffer();
    for (final line in _quick) {
      buffer.writeln(_bold(lightGreen, line));
    }
    for (final line in _patch) {
      buffer.writeln(_bold(green, line));
    }
    return buffer.toString();
  }

  /// A compact inline lockup for one-line headers: "⚡ QuickPatch".
  static String wordmark() => '${green.wrap('⚡')} ${_bold(green, 'QuickPatch')}';

  /// Logo + tagline + version + a hairline rule. Used as a header for `--help`.
  static String header() {
    final tagline = darkGray.wrap(_tagline);
    final version = darkGray.wrap('v$packageVersion');
    final rule = darkGray.wrap('─' * 46);
    return '\n${logo()}\n  $tagline   $version\n  $rule\n';
  }

  /// The welcome banner shown at the top of `quickpatch init` — a friendly
  /// wizard intro in the spirit of a project scaffolder.
  static String welcome() {
    final intro = StringBuffer()
      ..writeln(header())
      ..writeln(
        "  You're about to set up ${_bold(green, 'QuickPatch')} in this project.",
      )
      ..writeln(
        '  ${styleDim.wrap('This wizard registers your app and wires up over-the-air patches.')}',
      );
    return intro.toString();
  }
}
