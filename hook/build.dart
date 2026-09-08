import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await const RustBuilder(
      assetName: 'src/native.dart',
      extraCargoBuildArgs: ['--locked'],
      // Keep Rust and transitive C libraries on the same iOS deployment floor.
      extraCargoEnvironmentVariables: {'IPHONEOS_DEPLOYMENT_TARGET': '13.0'},
    ).run(input: input, output: output);
  });
}
