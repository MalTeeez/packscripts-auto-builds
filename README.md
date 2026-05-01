# packscripts auto builds
This repo contains manifests for distributing modpacks.

## getting started as a user
Just import the starter zip into prism, as can be done directly via this link `https://github.com/MalTeeez/packscripts-auto-builds/raw/refs/heads/gtnh-daily/GTNH%20Daily-client.zip` (for the newest version) or by manually downloading it (and then importing).

Next, select your java 25 isntall under the instance settings, and tick the "Skip java compatability checks" box.

That's it, just launch the game now!

## downgrading
Sometimes you will want to go back a version, or select a specific version.

To do this, just set the `-Dunsup.versionSelectorOnLaunch` JVM argument from `false` to `true`, and you should be getting a version selector popup on launch.
