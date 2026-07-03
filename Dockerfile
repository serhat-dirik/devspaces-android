# Developer workspace image: Flutter + Android SDK + adb, on the Red Hat Universal
# Developer Image (UDI) base. Built on the cluster (openshift/buildconfig.yaml).
#
# The workspace builds the app and drives the on-cluster Android device (redroid,
# running in a separate KubeVirt VM) over adb — it does NOT run an emulator itself.
#
# Supply chain (QA M4): a running workspace pulls the FROZEN `mobile-allinone`
# ImageStream tag — resolved to a digest at build time — so its runtime IS pinned
# and never re-resolves the upstreams below. The `:latest`/`stable` refs here float
# only at REBUILD time, a deliberate admin action (openshift/build-and-deploy.sh),
# and are kept current so each rebuild picks up Red Hat CVE fixes. For a locked-down
# build, pin them by digest/tag (udi-rhel9@sha256:…, a Flutter release tag, a fixed
# cmdline-tools zip + checksum). The RUNTIME-pulled images a workspace fetches
# without a rebuild — oauth-proxy, ws-scrcpy — are pinned by digest in provision-device.sh.
FROM registry.redhat.io/devspaces/udi-rhel9:latest
USER 0
RUN dnf -y install unzip which procps-ng rsync && dnf clean all

# --- Arbitrary-UID JVM/Gradle fix (QA C3) ----------------------------------
# OpenShift runs the workspace pod as an unmapped UID (e.g. 1001) in group 0
# with NO /etc/passwd entry, so the JVM resolves user.home=? and Gradle's
# Android plugin builds the debug-keystore path as .../?/.android/debug.keystore,
# failing :app:packageDebug. Pin a stable, writable HOME so `flutter build apk`
# works first-try under any UID:
#   - JAVA_TOOL_OPTIONS forces the JVM to a real home regardless of getpwuid().
#   - HOME points at /home/user (made GID-0 writable below) so Gradle/Flutter
#     caches and the debug keystore land somewhere writable.
ENV HOME=/home/user
ENV JAVA_TOOL_OPTIONS="-Duser.home=/home/user"
ENV GRADLE_USER_HOME=/home/user/.gradle
# QA L1: Dart/Flutter's pub cache reads OS $HOME; pin it explicitly so the build
# doesn't depend on HOME being inherited (belt-and-suspenders with HOME above).
ENV PUB_CACHE=/home/user/.pub-cache
# Baked passwd entry for UID 1001 (the common restricted-v2 case) so id/whoami
# resolve there. (QA M1/L5: we deliberately do NOT chmod /etc/passwd group-writable
# — that only helps if a startup entrypoint appends the live UID, and this image
# ships none. For *other* arbitrary UIDs id/whoami just print the numeric id, which
# is cosmetic: the actual `flutter build apk` fix is UID-INDEPENDENT —
# HOME/JAVA_TOOL_OPTIONS/GRADLE_USER_HOME above pin a writable home regardless of
# getpwuid() — and is verified to build first-try under any UID.)
RUN echo 'user:x:1001:0:Workspace User:/home/user:/bin/bash' >> /etc/passwd

# --- Android SDK (command-line tools, platform-tools/adb, platform, build-tools) ---
ENV ANDROID_SDK_ROOT=/opt/android-sdk
# build-tools on PATH (QA M2) so `aapt` resolves — run-on-device.sh's package
# detection falls back to `aapt dump badging` on the built APK.
ENV PATH=$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/build-tools/34.0.0
ARG CLI_TOOLS=commandlinetools-linux-11076708_latest.zip
# OpenShift builds inject empty HTTP(S)_PROXY env vars from the cluster Proxy
# object; the JVM-based sdkmanager rejects "" as a malformed URL. Unset them
# in-shell (a no-op under local podman) so the SDK tools run.
RUN unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
 && mkdir -p $ANDROID_SDK_ROOT/cmdline-tools \
 && curl -fsSL https://dl.google.com/android/repository/$CLI_TOOLS -o /tmp/cli.zip \
 && unzip -q /tmp/cli.zip -d $ANDROID_SDK_ROOT/cmdline-tools \
 && mv $ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools \
       $ANDROID_SDK_ROOT/cmdline-tools/latest && rm /tmp/cli.zip \
 && yes | sdkmanager --licenses >/dev/null \
 && sdkmanager --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" \
 && chgrp -R 0 $ANDROID_SDK_ROOT \
 && chmod -R g=u $ANDROID_SDK_ROOT

# --- Flutter ---
ENV FLUTTER_HOME=/opt/flutter
ENV PATH=$PATH:$FLUTTER_HOME/bin
RUN unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
 && git clone --depth 1 -b stable https://github.com/flutter/flutter.git $FLUTTER_HOME \
 && git config --system --add safe.directory $FLUTTER_HOME \
 && flutter config --no-analytics --enable-web \
 && flutter precache --android --web \
 && chgrp -R 0 $FLUTTER_HOME /home/user \
 && chmod -R g=u $FLUTTER_HOME /home/user

# Ownership/permissions for OpenShift's arbitrary UID (group 0) are set inline in
# each install RUN above — NOT in a trailing chmod -R over the whole tree, which
# would force an overlayfs copy-up that duplicates the toolchain into a new layer.

# --- device-management scripts: the developer's "Device: *" IDE tasks + terminal ---
COPY scripts/ /usr/local/bin/
# chmod ALL of them (mobile-help has no .sh suffix), and greet developers with a
# one-line "type mobile-help" banner on terminal open so the device commands are
# discoverable WITHOUT reading the README. Covers interactive (.bashrc) and login
# (/etc/profile.d) shells; arbitrary-UID safe because HOME=/home/user (GID-0 writable)
# is pinned above.
RUN chmod -R a+rx /usr/local/bin \
 && printf '\n[ -t 1 ] && command -v mobile-help >/dev/null 2>&1 && mobile-help --banner\n' >> /home/user/.bashrc \
 && printf '#!/bin/sh\n[ -t 1 ] && command -v mobile-help >/dev/null 2>&1 && mobile-help --banner\n' > /etc/profile.d/00-mobile-help.sh \
 && chmod a+rx /etc/profile.d/00-mobile-help.sh \
 && chgrp 0 /home/user/.bashrc && chmod g=u /home/user/.bashrc
USER 1001
