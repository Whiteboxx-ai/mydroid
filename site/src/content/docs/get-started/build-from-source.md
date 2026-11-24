---
title: Build Mydroid from source
description: Compile the Mac app and Android APK, then pair with the same setup as a downloaded build.
---

Build either app yourself or [install the published builds](/get-started/). Both paths use the same pairing flow.

Clone the repository on your Mac.

```sh
git clone https://github.com/Whiteboxx-ai/mydroid.git
cd mydroid
```

## Build for Mac

Install Xcode and open it once to finish setup. Run these commands from the repository.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./mac/scripts/build-app.sh
open build/Mydroid.app
```

The app opens its pairing window. If a rebuild leaves an enabled Accessibility switch stuck, use **Reset and ask again** on the Mac permission card.

## Build for Android

1. Open the repository’s `android` folder in Android Studio.
2. Install Android SDK Platform 36 and a Java 17 JDK. Let Android Studio sync the project so it knows where to find the SDK.
3. In Terminal, run these commands from the repository.

```sh
cd android
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
./gradlew :app:assembleDebug
```

Copy `android/app/build/outputs/apk/debug/app-debug.apk` from the repository to your phone. Open it and [follow the Android install guide](/get-started/install-android/). You can also use Android Studio’s **Run** button with a test phone or emulator.

Android requires updates to use the same signing key as the installed app. A local debug APK and the published APK use different keys. Use a test device to try a local build, or make an Authenticator backup before changing builds on your main phone.

## Pair and test

[Pair your Android and Mac](/get-started/pair/). Then use **Share → Mydroid** on Android to send a link to your Mac.

The Chrome extension source ships with your Mac build. Use [the Authenticator guide](/features/authenticator/#fill-in-the-browser) to load it.
