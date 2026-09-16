#!/bin/bash
# This script does NOT create anything in your keychain – code-signing
# certificate creation is something only you should do interactively
# (it touches Keychain trust settings). This just prints the exact steps.
#
# WHY: ad-hoc signing (`codesign --sign -`) produces a different signature
# hash on every rebuild. macOS's TCC/Full Disk Access grant is keyed to
# that signature, so every rebuild silently revokes FDA and you'd have to
# re-grant it in System Settings each time. A stable self-signed cert with
# a fixed identity fixes this permanently.

cat <<'EOF'
=== One-time setup: stable self-signed code-signing certificate ===

1. Open Keychain Access (Applications > Utilities > Keychain Access).

2. Menu bar: Keychain Access > Certificate Assistant > Create a Certificate…

3. Fill in the dialog:
     Name:                ActivityHeatmap Dev
     Identity Type:       Self Signed Root
     Certificate Type:    Code Signing
     [x] Let me override defaults   <- check this box

4. Click Continue through the wizard. On the "Specify a Location For The
   Certificate" (keychain) screen, choose "login" keychain. Accept the
   rest of the defaults (validity period 365 days is fine – you can
   regenerate later, see step 6) and click Create, then Done.

5. Verify it landed correctly:
     security find-identity -v -p codesigning
   You should see a line like:
     1) <SHA1> "ActivityHeatmap Dev"

   If codesign later complains about trust, open Keychain Access, find
   the "ActivityHeatmap Dev" certificate under the "login" keychain,
   double-click it, expand "Trust", and set "Code Signing" to
   "Always Trust". You'll be prompted for your login password once.

6. That's it. build.sh already looks for an identity named exactly
   "ActivityHeatmap Dev" and will use it automatically once it exists –
   no further changes needed. Every subsequent ./build.sh run will
   produce the SAME signature, so Full Disk Access (granted in step C
   of STAGE1.md) survives rebuilds.

Note: if you ever need to redo this (e.g. cert expires), the bundle
identifier (com.local.activityheatmap) stays the same in build.sh, but a
NEW certificate means a NEW signing identity, which macOS treats as a
different signer – you'd need to re-grant Full Disk Access once after
switching certs. Keep this cert around; don't regenerate it casually.
EOF
