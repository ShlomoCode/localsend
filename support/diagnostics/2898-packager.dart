import "dart:convert";
import "dart:io";
import "package:flutter_app_packager/flutter_app_packager.dart";
import "package:unified_distributor/unified_distributor.dart";

Future<void> main() async {
  // Use the same packager API and shell executor that flutter_distributor calls
  // after its build. The verified bundle is already built, so do not rebuild it.
  UnifiedDistributor("flutter_distributor", "Flutter Distributor");
  final result = await FlutterAppPackager().package(
    "linux", "deb", {"build_mode": "release"}, Directory("dist/"),
    buildOutputDirectory: Directory("build/linux/x64/release/bundle"),
    buildOutputFiles: [],
  );
  print(const JsonEncoder.withIndent("  ").convert(result.toJson()));
}
