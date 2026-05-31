import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/commands/login_command.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(LoginCommand, () {
    const email = 'test@email.com';

    late Auth auth;
    late http.Client httpClient;
    late Directory applicationConfigHome;
    late QuickPatchLogger logger;
    late LoginCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          authRef.overrideWith(() => auth),
          loggerRef.overrideWith(() => logger),
        },
      );
    }

    setUp(() {
      applicationConfigHome = Directory.systemTemp.createTempSync();
      auth = MockAuth();
      httpClient = MockHttpClient();
      logger = MockQuickPatchLogger();

      when(() => auth.isAuthenticated).thenReturn(false);
      when(() => auth.client).thenReturn(httpClient);
      // `login` prompts for an API key via the logger, then validates it.
      when(() => logger.prompt(any())).thenReturn('qp_api_test');
      when(() => auth.loginWithApiKey(any())).thenAnswer((_) async {});
      when(
        () => auth.credentialsFilePath,
      ).thenReturn(p.join(applicationConfigHome.path, 'credentials.json'));
      when(
        () => auth.login(prompt: any(named: 'prompt')),
      ).thenAnswer((_) async {});

      command = runWithOverrides(LoginCommand.new);
    });

    test('has correct name', () {
      expect(command.name, 'login');
    });

    test('has correct description', () {
      expect(command.description, 'Login as a new QuickPatch user.');
    });

    group('when user is already logged in', () {
      setUp(() {
        when(() => auth.isAuthenticated).thenReturn(true);
        when(() => auth.email).thenReturn(email);
      });

      test(
        'prints message and exits with code 0 when already logged in',
        () async {
          final result = await runWithOverrides(command.run);

          expect(result, equals(ExitCode.success.code));
          verify(
            () => logger.info('You are already logged in as <$email>.'),
          ).called(1);
          verify(
            () => logger.info(
              '''Run ${lightCyan.wrap('quickpatch logout')} to log out and try again.''',
            ),
          ).called(1);
          verifyNever(() => auth.login(prompt: any(named: 'prompt')));
        },
      );
    });

    group('when user is authenticated via API key', () {
      setUp(() {
        when(() => auth.isAuthenticated).thenReturn(true);
        when(() => auth.email).thenReturn(null);
      });

      test('prints API key message and exits with code 0', () async {
        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(
          () => logger.info('You are already authenticated via API key.'),
        ).called(1);
        verify(
          () => logger.info(
            '''Run ${lightCyan.wrap('quickpatch logout')} to log out and try again.''',
          ),
        ).called(1);
        verifyNever(() => auth.login(prompt: any(named: 'prompt')));
      });
    });

    test('exits with usage code when the API key format is invalid', () async {
      when(() => logger.prompt(any())).thenReturn('not-a-valid-key');

      final result = await runWithOverrides(command.run);
      expect(result, equals(ExitCode.usage.code));

      verify(
        () => logger.err(any(that: contains('Invalid API key format'))),
      ).called(1);
      verifyNever(() => auth.loginWithApiKey(any()));
    });

    test('exits with code 70 when the API key is not recognized', () async {
      when(
        () => auth.loginWithApiKey(any()),
      ).thenThrow(ApiKeyNotFoundException());

      final result = await runWithOverrides(command.run);
      expect(result, equals(ExitCode.software.code));

      verify(
        () => logger.err(any(that: contains('API key not recognized'))),
      ).called(1);
    });

    test('exits with code 70 when error occurs', () async {
      final error = Exception('oops something went wrong!');
      when(() => auth.loginWithApiKey(any())).thenThrow(error);

      final result = await runWithOverrides(command.run);
      expect(result, equals(ExitCode.software.code));

      verify(() => auth.loginWithApiKey(any())).called(1);
      verify(() => logger.err(error.toString())).called(1);
    });

    test('exits with code 0 when logged in successfully', () async {
      final result = await runWithOverrides(command.run);
      expect(result, equals(ExitCode.success.code));

      verify(() => auth.loginWithApiKey('qp_api_test')).called(1);
      verify(
        () => logger.info(any(that: contains('You are now logged in.'))),
      ).called(1);
    });
  });
}
