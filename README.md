# Ghostty Vertical Tabs

A vertical tab sidebar for [Ghostty](https://ghostty.org) on macOS.

Ghostty has no plugin system and no setting for vertical tabs on macOS. This is a small
companion app that docks a sidebar next to your Ghostty window, lists your tabs top to
bottom, and switches between them when you click one.

Not affiliated with the Ghostty project.

## How it works

On macOS, Ghostty keeps its tabs in the title bar, and hiding the title bar
(`macos-titlebar-style = hidden`) turns every new tab into its own window. This app leans
into that:

- **Every Ghostty window is a tab.** The sidebar lists them in the order you opened them.
- **The windows are stacked in one spot.** When you switch, the window you pick is moved
  onto the same frame as the last one, so it looks and feels like one window with tabs.
  Move or resize the front window and the rest follow when you switch to them.
- **Ghostty's title bar is hidden** through its config file, so there's no horizontal tab bar.

Under the hood it uses Ghostty's AppleScript dictionary (Ghostty 1.3+) to list, focus,
open and close windows, and the macOS Accessibility API to move them.

## Requirements

- macOS 13 or later
- Ghostty 1.3 or later (the first version with AppleScript support)

## Install

```bash
git clone https://github.com/nmaties/ghostty-vertical-tabs.git
cd ghostty-vertical-tabs
./scripts/build-app.sh
cp -R "build/Ghostty Vertical Tabs.app" /Applications/
open "/Applications/Ghostty Vertical Tabs.app"
```

On first launch the app:

1. Offers to hide Ghostty's title bar. This adds a marked block to your Ghostty config
   (`~/.config/ghostty/config` if it exists, otherwise
   `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`):

   ```
   # >>> ghostty-vertical-tabs >>>
   macos-titlebar-style = hidden
   window-padding-x = 10
   window-padding-y = 10
   # <<< ghostty-vertical-tabs <<<
   ```

   Without the title bar the terminal text would touch the window's edges, so the block also
   adds 10 pt of padding. Each padding line is left out if your config already sets that
   option itself. Ghostty applies the title bar change to new windows, so open a fresh window
   (or restart Ghostty) afterwards. When you update the app, it brings this block up to date
   on its next launch.

   Ghostty applies the title bar change only to new windows, so the app then offers to
   reopen your current windows in the same folders. Anything running in them stops, and
   Ghostty asks first if a command is still running.
2. Asks for **Accessibility** access, to stack Ghostty's windows in one spot and to move
   them with the grab bar. Until it's granted, the sidebar shows a notice at the top and
   the grab bar asks for it instead of moving anything.
3. Asks to **control Ghostty** (Automation), to read the window list and switch windows.

Grant both in System Settings › Privacy & Security.

### Keeping permissions across rebuilds

An ad hoc signed build gets a new identity every time you rebuild, and macOS drops its
permissions. Sign with your own certificate to keep them:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

## Use

- Click a tab to switch to it. Hover a tab and click **×** to close it.
- Double-click a tab to rename it. Ghostty's own "Change Tab Title" dialog opens on that
  tab; leave it blank to go back to the title your shell sets. Ghostty keeps the name when
  you switch tabs or run commands.
- Drag the grab bar at the top of the sidebar to move the terminal. Ghostty's title bar is
  hidden, so this replaces dragging by the title bar. Resize from the window's edges as usual.
- **New Tab** opens a Ghostty window in the current tab's folder. `⌘T` in Ghostty works too.
- The sidebar only shows while Ghostty is the active app, and hides for fullscreen windows.

The menu bar icon has:

- **Dock on Left / Dock on Right**. If there isn't room on the chosen side, the sidebar
  uses the other one.
- **Hide Ghostty's Title Bar (One Window per Tab)** adds or removes the config block above.
  With it off, the sidebar lists Ghostty's windows without stacking them.
- **Open at Login**
- **Quit**

## Limitations

- Ghostty's own "next/previous tab" key bindings don't apply, because every tab is a window.
  Use the sidebar, or `` ⌘` `` to cycle windows.
- Windows of the same Ghostty instance are all treated as one group of tabs.
- The sidebar is a separate window, so Mission Control shows it next to Ghostty's windows.

## License

MIT
