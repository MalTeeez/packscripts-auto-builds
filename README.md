# packscripts auto builds
This repo contains manifests for distributing modpacks.

## getting started as a user

### for clients (prism)
Just import the starter zip into prism, as can be done directly via this link `https://github.com/MalTeeez/packscripts-auto-builds/raw/refs/heads/gtnh-daily/GTNH%20Daily-client.zip` (for the newest version) or by manually downloading it (and then importing).

Next, select your java 25 install under the instance settings, and tick the "Skip java compatability checks" box.

That's it, just launch the game now!

### for servers (TBD; BROKEN FOR NOW)
Download the starter zip from `https://github.com/MalTeeez/packscripts-auto-builds/raw/refs/heads/gtnh-daily/GTNH%20Daily-server.zip` (make sure to follow redirects), and unzip it.

Make sure you agree to the eula before starting.
Then, proceed as you would normally for your server. If you just want to use the GTNH-provided scripts, that would be: `sh startserver-java9.sh` or `startserver-java9.bat` for windows.

## downgrading
Sometimes you will want to go back a version, or select a specific version.

To do this, just set the `-Dunsup.versionSelectorOnLaunch` JVM argument from `false` to `true`, and you should be getting a version selector popup on launch.
