# Cloud Mobile Starter

A minimal Flutter starter whose Android APK is built on GitHub Actions. No
Android SDK, Java installation, or emulator is required on the development
machine.

## Cloud build

Use this folder as the root of its own GitHub repository. The workflow at
`.github/workflows/build.yml` installs Java 17 and Flutter on a GitHub-hosted
runner, generates the Android platform files, sets Android `minSdk` to 21,
runs analysis and tests, and builds a release APK.

After a successful run, download the `cloud-mobile-starter-apk` artifact from
the workflow run's **Artifacts** section.

The generated APK is not signed with a production release key. Configure
signing secrets and a release-signing Gradle setup before distributing an
app publicly.
