import 'dart:io';

import 'package:args/args.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:quickpatch_jwt/quickpatch_jwt.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:quickpatch_cli/src/abi.dart';
import 'package:quickpatch_cli/src/android_sdk.dart';
import 'package:quickpatch_cli/src/android_studio.dart';
import 'package:quickpatch_cli/src/archive_analysis/archive_analysis.dart';
import 'package:quickpatch_cli/src/archive_analysis/archive_differ.dart';
import 'package:quickpatch_cli/src/artifact_builder/artifact_builder.dart';
import 'package:quickpatch_cli/src/artifact_manager.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/cache.dart' show Cache;
import 'package:quickpatch_cli/src/checksum_checker.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/code_signer.dart';
import 'package:quickpatch_cli/src/commands/patch/patch.dart';
import 'package:quickpatch_cli/src/commands/release/releaser.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/doctor.dart';
import 'package:quickpatch_cli/src/engine_config.dart';
import 'package:quickpatch_cli/src/executables/devicectl/apple_device.dart';
import 'package:quickpatch_cli/src/executables/executables.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/network_checker.dart';
import 'package:quickpatch_cli/src/os/os.dart';
import 'package:quickpatch_cli/src/patch_diff_checker.dart';
import 'package:quickpatch_cli/src/platform/platform.dart';
import 'package:quickpatch_cli/src/pubspec_editor.dart';
import 'package:quickpatch_cli/src/quickpatch_android_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_cli_command_runner.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_flutter.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_cli/src/quickpatch_version.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

class MockAbi extends Mock implements LocalAbi {}

class MockAccessCredentials extends Mock implements AccessCredentials {}

class MockAdb extends Mock implements Adb {}

class MockAndroidSdk extends Mock implements AndroidSdk {}

class MockAndroidStudio extends Mock implements AndroidStudio {}

class MockAotTools extends Mock implements AotTools {}

class MockApple extends Mock implements Apple {}

class MockAppMetadata extends Mock implements AppMetadata {}

class MockAppleDevice extends Mock implements AppleDevice {}

class MockArchiveDiffer extends Mock implements ArchiveDiffer {}

class MockArgParser extends Mock implements ArgParser {}

class MockArgResults extends Mock implements ArgResults {}

class MockArtifactBuildException extends Mock
    implements ArtifactBuildException {}

class MockArtifactBuilder extends Mock implements ArtifactBuilder {}

class MockArtifactManager extends Mock implements ArtifactManager {}

class MockAuth extends Mock implements Auth {}

class MockBundleTool extends Mock implements Bundletool {}

class MockCache extends Mock implements Cache {}

class MockChecksumChecker extends Mock implements ChecksumChecker {}

class MockCodePushClient extends Mock implements CodePushClient {}

class MockCodePushClientWrapper extends Mock implements CodePushClientWrapper {}

class MockCodeSigner extends Mock implements CodeSigner {}

class MockDevicectl extends Mock implements Devicectl {}

class MockDiff extends Mock implements Diff {}

class MockDitto extends Mock implements Ditto {}

class MockDirectory extends Mock implements Directory {}

class MockDoctor extends Mock implements Doctor {}

class MockEngineConfig extends Mock implements EngineConfig {}

class MockFile extends Mock implements File {}

class MockFileSetDiff extends Mock implements FileSetDiff {}

class MockFlavorValidator extends Mock implements FlavorValidator {}

class MockGit extends Mock implements Git {}

class MockGradlew extends Mock implements Gradlew {}

class MockHttpClient extends Mock implements http.Client {}

class MockIDeviceSysLog extends Mock implements IDeviceSysLog {}

class MockIOSDeploy extends Mock implements IOSDeploy {}

class MockIOSink extends Mock implements IOSink {}

class MockJava extends Mock implements Java {}

class MockJwtHeader extends Mock implements JwtHeader {}

class MockJwtPayload extends Mock implements JwtPayload {}

class MockLinux extends Mock implements Linux {}

class MockNetworkChecker extends Mock implements NetworkChecker {}

class MockOpen extends Mock implements Open {}

class MockOperatingSystemInterface extends Mock
    implements OperatingSystemInterface {}

class MockPatchDiffChecker extends Mock implements PatchDiffChecker {}

class MockPatchExecutable extends Mock implements PatchExecutable {}

class MockPatcher extends Mock implements Patcher {}

class MockPlatform extends Mock implements Platform {}

class MockPowershell extends Mock implements Powershell {}

class MockProcessResult extends Mock implements QuickPatchProcessResult {}

class MockProcessSignal extends Mock implements ProcessSignal {}

class MockProcessWrapper extends Mock implements ProcessWrapper {}

class MockProcess extends Mock implements Process {}

class MockProgress extends Mock implements Progress {}

class MockPubspec extends Mock implements Pubspec {}

class MockPubspecEditor extends Mock implements PubspecEditor {}

class MockRelease extends Mock implements Release {}

class MockReleaser extends Mock implements Releaser {}

class MockReleaseArtifact extends Mock implements ReleaseArtifact {}

class MockQuickPatchAndroidArtifacts extends Mock
    implements QuickPatchAndroidArtifacts {}

class MockQuickPatchArtifacts extends Mock implements QuickPatchArtifacts {}

class MockQuickPatchCliCommandRunner extends Mock
    implements QuickPatchCliCommandRunner {}

class MockQuickPatchEnv extends Mock implements QuickPatchEnv {}

class MockQuickPatchFlutter extends Mock implements QuickPatchFlutter {}

class MockQuickPatchLogger extends Mock implements QuickPatchLogger {}

class MockQuickPatchProcess extends Mock implements QuickPatchProcess {}

class MockQuickPatchProcessResult extends Mock
    implements QuickPatchProcessResult {}

class MockQuickPatchValidator extends Mock implements QuickPatchValidator {}

class MockQuickPatchVersion extends Mock implements QuickPatchVersion {}

class MockQuickPatchYaml extends Mock implements QuickPatchYaml {}

class MockStdin extends Mock implements Stdin {}

class MockStdout extends Mock implements Stdout {}

class MockValidator extends Mock implements Validator {}

class MockWindows extends Mock implements Windows {}

class MockXcodeBuild extends Mock implements XcodeBuild {}
