# Installing KeyPoint OSC

KeyPoint OSC lets Bitfocus Companion control PowerPoint for Mac and Keynote. Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

## 1. Install the app (on the presentation Mac)

1. Download `KeyPoint-OSC-<version>.zip` from the [latest release](https://github.com/BasilChessman/KeyPoint-OSC/releases/latest).
2. Open the zip, and drag **KeyPoint OSC** into **Applications**.
3. Double-click it. macOS says it "can't be opened" or "can't verify" it, because the app isn't notarized by Apple. Click **Done**.
4. Open **System Settings > Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to "KeyPoint OSC". Enter your password, then click **Open Anyway** again.

You only do steps 3–4 once per version. A slides icon appears in the menu bar; there's no Dock icon.

(Shortcut for Terminal users, instead of steps 3–4: `xattr -dr com.apple.quarantine "/Applications/KeyPoint OSC.app"`)

## 2. Allow permissions

- **Automation:** the first time KeyPoint controls PowerPoint or Keynote, macOS asks whether it may. Click **OK** (or **Allow**).
- **Accessibility** (recommended): click the menu-bar icon, and under **Permissions** click **Allow…** next to Accessibility. Then turn on **KeyPoint OSC** in the list that opens. This enables smooth go-to-slide and presentation switching in PowerPoint, and black/white screen in Keynote.
- **Incoming connections:** when macOS asks whether KeyPoint OSC may accept incoming network connections, click **Allow**. Companion on another computer needs this.

Updates keep these permissions, as long as the app comes from these releases.

## 3. Set up Companion

1. Download `rustedroof-keypoint-osc-<version>.tgz` from the same release.
2. In the Companion web interface, open **Modules**, choose **Import module package**, and select the `.tgz`.
3. Under **Connections**, add **KeyPoint OSC**. Enter the presentation Mac's IP address (shown in the KeyPoint menu as **This Mac**) and leave the port at **35551**.
4. The connection turns green when KeyPoint answers. Presets are under **Buttons > Presets > KeyPoint OSC**.

## Updating

Download the new zip and replace the app in Applications. Repeat the **Open Anyway** step, then import the new module `.tgz` in Companion.

## Troubleshooting

- **Connection stays red or "Waiting"**: check the IP; that both computers are on the same network; and that KeyPoint OSC is running (menu-bar icon). Then check System Settings > Network > Firewall on the Mac: KeyPoint OSC should be allowed.
- **Nothing happens in PowerPoint/Keynote, and the menu icon shows a warning triangle**: Automation was denied. Fix it under System Settings > Privacy & Security > Automation > KeyPoint OSC.
- **"Allow…" stays visible after granting Accessibility**: in the Accessibility list, select KeyPoint OSC, remove it with **–**, then click **Allow…** in the KeyPoint menu again.
- More in the [README](../README.md#troubleshooting).
