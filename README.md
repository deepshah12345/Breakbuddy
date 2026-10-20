# BreakBuddy

A native macOS menu bar app (Swift + SwiftUI, macOS 13+, no third-party dependencies).
A cartoon character pops up in the bottom-right corner of your screen to remind you to
drink water and take breaks, then slides away.

> **Build status:** the code was written in a Linux sandbox with no Swift/Xcode toolchain,
> so it has **not been compiled or run yet**. Your first Xcode build is the first real compile.
> If you hit an error, paste it back and I'll fix it. See "Testing checklist" below.

## 1. Open and run in Xcode

1. Requires macOS 13+ and Xcode 15+.
2. Double-click `BreakBuddy.xcodeproj`.
3. Select the **BreakBuddy** scheme and **My Mac** as the destination.
4. Signing is set to "Sign to Run Locally" (ad-hoc), so no developer account is needed.
   If Xcode complains, open the target's *Signing & Capabilities* tab and pick your Personal Team.
5. Press **Cmd+R**. A drop icon appears in the menu bar (no Dock icon).
6. Click it, then **Remind me now** to see the popup straight away.

Optional: `project.yml` lets you regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen && xcodegen generate`).

## 2. Menu bar menu

- Next due time for each reminder type
- **Pause / Resume** (resuming restarts all countdowns)
- **Remind me now** (alternates between a water and a break test; ignores schedule filters)
- **Settings...**
- **Quit**

## 3. Add your own character images

**Easiest, no rebuild:** Settings > Character > **Choose...** for Idle, Blink, or Wave.
Use transparent PNGs (about 512x512 works well). Images are copied to
`~/Library/Application Support/BreakBuddy/`. **Reset** returns to the built-in one.

**Bake them into the app:** in Xcode open `Assets.xcassets` and replace the image in
`character_idle`, `character_blink` (optional), `character_wave` (optional).
Keep those exact set names. A custom image chosen in Settings takes priority over the catalog.

How they're used: Idle is always shown and bobs gently. If Blink exists, it is swapped in
briefly every few seconds. If Wave exists, it shows for the first ~1.5 s when the character arrives.

The included placeholders are a simple water-drop buddy (idle / blink / wave).

## 4. Change intervals and messages

Settings window, per reminder type (Water default 45 min, Break default 60 min):

- **Enabled** toggle
- **Every N min** slider (5 to 180 min, steps of 5)
- **Messages** box, one per line; a random one is picked each time
- **Preview** button to test it

To change the defaults used on first launch, edit `defaultConfig` in `Models.swift`.
Other settings: working hours (e.g. 9:00-18:00, weekdays only), sound on/off,
skip during Do Not Disturb/Focus, launch at login. All persist in UserDefaults.

### Custom reminders and per-reminder characters

Besides Water and Break you can add your own reminders: open **Settings…** and press **Add custom reminder**. Each custom reminder has its own name, menu/bubble icon, interval, message list and "keep until Done" option, and can be deleted again (Water and Break can't be deleted).

Every reminder can also have its own character. Expand **Character for this reminder** and pick PNGs for Idle / Blink / Wave. Anything you don't set falls back to the **Default character**, then to the built-in artwork. Per-reminder images are stored in `~/Library/Application Support/BreakBuddy/reminders/<id>/`.

### Per-reminder schedules

By default every reminder follows the global **Working hours** section. To give one reminder different times, switch on **Use its own schedule** inside that reminder: pick a From/To time and the days (Mon to Sun, with "Every day" and "Weekdays" shortcuts; the global working hours have the same day picker). A reminder's countdown restarts when its window opens, and it stays quiet outside it.

## 5. Build a release .app and add it to Login Items

1. In Xcode: **Product > Archive** (or **Product > Build For > Profiling** for a quick Release build).
2. In the Organizer choose **Distribute App > Copy App** (or **Direct Distribution** if you have a
   Developer ID), and save `BreakBuddy.app`.
   Command-line alternative: `xcodebuild -scheme BreakBuddy -configuration Release -derivedDataPath build`
   then take `build/Build/Products/Release/BreakBuddy.app`.
3. Drag `BreakBuddy.app` into **/Applications**.
4. First launch of an unsigned/ad-hoc app: right-click > **Open** once to get past Gatekeeper.
5. Start at login, either way:
   - Open BreakBuddy > Settings > turn on **Launch at login** (uses `SMAppService`; if macOS asks,
     approve it in System Settings > General > Login Items), **or**
   - System Settings > General > Login Items > **+** > pick BreakBuddy.app.

If you share the app with others, sign with a Developer ID and notarize it
(hardened runtime is already on).

## 6. Permissions and entitlements

| Item | Needed? | Notes |
|---|---|---|
| App Sandbox | **Off** (`BreakBuddy.entitlements`) | Lets the app read the Focus state file. Turning it on still works, but Focus detection stops. |
| Accessibility / Input Monitoring | No | Idle time uses `CGEventSource`, which needs no permission. |
| Full Disk Access | **Optional** | Only for Do Not Disturb / Focus detection (see below). |
| Network, camera, mic, location | No | |
| Login item | Approval may be requested | Only if you enable Launch at login. |

**Focus / Do Not Disturb detection is best effort.** Apple has no public API. The app reads
`~/Library/DoNotDisturb/DB/Assertions.json`, which macOS only lets it read with Full Disk Access
(System Settings > Privacy & Security > Full Disk Access > add BreakBuddy). Without that, detection
quietly reports "off" and reminders are never wrongly blocked. Turn the option off in Settings if you prefer.

## 7. How the smart scheduling works

- One 5-second tick timer compares the clock with each reminder's next-fire time (`ReminderScheduler.swift`).
- **Away rule:** BreakBuddy only counts time while you're at your Mac. "Away" means asleep, display off, screen locked, another user's session in front, or no keyboard/mouse for 5 minutes. While away every countdown freezes, and when you return it continues where it stopped. Nothing pops up on an empty screen and there is no catch-up pile after a long absence. (Example: 7 minutes left, you leave for 2 hours, the reminder shows 7 minutes after you return.)
- **Sleep/wake:** time spent asleep doesn't count (also detected if a tick arrives after a >60 s gap). Nothing is shown the moment the Mac wakes.
- **Lock detection** uses macOS lock/unlock notifications that Apple doesn't document; the 5-minute idle check backs it up.
- **Focus on:** the reminder is retried 5 minutes later.
- **Working hours:** nothing fires outside them; countdowns restart when the window opens.
- **Queue:** the panel controller shows one popup at a time; others wait their turn (one per type).
- **Keep on screen until I tap Done:** the countdown for that reminder starts only after you tap **Done**, so an ignored popup never stacks with the next one. Other reminders start counting when the popup appears.
- **Snooze 10 min** hides the popup and brings it back in 10 minutes; for "keep until Done" reminders the normal interval then starts after you tap Done. **Done** (or the ~8 s timeout) dismisses it.

## 8. Project layout

```
BreakBuddy.xcodeproj
BreakBuddy/
  BreakBuddyApp.swift           App entry + AppDelegate wiring
  MenuBarController.swift       Status item + menu
  ReminderScheduler.swift       Timer-based, injectable clock/system state (testable)
  ReminderPanelController.swift NSPanel, queue, positioning, click-through
  ReminderView.swift            SwiftUI popup + view model (animation, blink/wave)
  SettingsView.swift            Settings window
  Models.swift                  ReminderType, ReminderConfig, AppSettings
  CharacterStore.swift          Asset catalog + custom image loading
  SystemState.swift             Idle time + Focus detection
  Assets.xcassets/              Placeholder character images
  Info.plist                    LSUIElement = true
  BreakBuddy.entitlements
Tests/ReminderSchedulerTests.swift   (add to a Unit Testing Bundle target)
```

## 9. Testing checklist (please run these, they're the parts I couldn't verify)

1. Build and run; confirm no Dock icon and a menu bar icon.
2. **Remind me now**: character slides in with a bounce, bobs, bubble shows; auto-leaves after ~8 s.
3. **Over a full-screen app:** put Safari/any app in full screen (green button), then use
   **Remind me now** from the menu bar (hover the top edge to reveal it). The popup should appear
   over it, on whatever Space you're on, and the full-screen app must keep keyboard focus.
4. **Click-through:** with the popup showing, click on apps behind the transparent area around the
   bubble. Clicks should reach them. Then click **Done** and **Snooze**; both should work on the first click.
5. Trigger two reminders back to back; the second should wait for the first to leave.
6. Sleep the Mac for a while and wake it; nothing should pop up right away, and the countdowns continue where they stopped. Lock the screen or turn the display off and check the same.
7. Optional: add the unit test target and press Cmd+U.

## 10. Known limitations

- Focus detection needs Full Disk Access and relies on an undocumented file that may change in future macOS versions.
- The popup appears on the screen that contains the key window (`NSScreen.main`).
- The popup is not keyboard-accessible by design (it never takes focus).
