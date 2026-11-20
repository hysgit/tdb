# Audio encoder notice: shine_dart 1.0.0

This notice covers only the MP3 encoding component. It does not assign a license to the surrounding application.

The application uses the unmodified `shine_dart` 1.0.0 package, a pure Dart translation of the Shine MP3 encoder. The package README states: “Copyright of the original code stays with the Shine authors. The changes of the translation are by Telosnex, under the same license.” The upstream project credits Gabriel Bouvigne, Pete Everett and Patrick Roberts in its history. These credits do not replace the original copyright notices retained in the source distributions.

- Package: https://pub.dev/packages/shine_dart/versions/1.0.0
- Exact source archive: https://pub.dev/api/archives/shine_dart-1.0.0.tar.gz
- Archive SHA-256: `e376b5150c2d0d9d1c99e96b6a05f5a26da369c62d906546bea47a3e2bb9c769`
- Dart source repository: https://github.com/Telosnex/shine_dart
- Original Shine project: https://github.com/toots/shine
- Complete license supplied with this release: [GNU Library General Public License, version 2, June 1991](licenses/shine_dart-LGPL-2.0.txt).

The actual package license is GNU Library GPL version 2. Its README explains the option described by section 13 for a library without a version specification. This project retains the supplied complete version 2 text; it does not relabel the component as MIT or decide a different application license.

## Source and rebuilding with a changed encoder

The source and build project accompanying this application include the caller in `lib/services/audio_tools.dart`, the PCM preparation bridge in `ios/Runner/TdbAudioTools.swift`, and `pubspec.yaml`/`pubspec.lock` identifying the component. Keep this corresponding project and these notices available with distributions; do not distribute only an opaque binary. No Shine source changes are required by this implementation.

To obtain the exact component source, from the application checkout:

```sh
mkdir -p third_party/shine_dart
curl -L -o shine_dart-1.0.0.tar.gz https://pub.dev/api/archives/shine_dart-1.0.0.tar.gz
shasum -a 256 shine_dart-1.0.0.tar.gz
tar -xzf shine_dart-1.0.0.tar.gz -C third_party/shine_dart
```

Check the hash against the value above. Edit the component source as needed, preserving its license and recording modifications. Add this local override to `pubspec.yaml`:

```yaml
dependency_overrides:
  shine_dart:
    path: third_party/shine_dart
```

Rebuild from the complete application project:

```sh
flutter pub get
flutter test test/audio_tools_test.dart
flutter build ipa --no-codesign
```

The last command requires macOS, Xcode and the iOS SDK. Use the recipient's own signing credentials for installation, or the project's existing signed build workflow. The test and unsigned build do not require the original author's signing secret. The application source permits replacing the encoder integration and recompiling; this notice does not add restrictions on reverse engineering needed to debug component modifications. Retain corresponding source, modifications, build scripts and notices with redistributed versions as required by the component license.
