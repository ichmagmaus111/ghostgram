# Ghostgram

**English** · [Русский](README.ru.md)

Ghostgram is an unofficial Telegram client for iOS. It is built on the official
[Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS) source code (13.0) and adds privacy,
message history and customization features. All of them are in one menu: **Settings → Ghostgram**.

Ghostgram is not affiliated with Telegram.

- Channel: [@ghostgrama](https://t.me/ghostgrama)
- Chat: [@ghostgramchat](https://t.me/ghostgramchat)
- Forum: [@ghostgramforum](https://t.me/ghostgramforum)

## Features

### Privacy

- **Ghost mode.** Read messages and view stories without marking them read or viewed, hide typing and
  the other activity statuses (recording a voice or video message, sending a photo, choosing a sticker…),
  stay offline or always online. "Read on action" marks a chat read when you reply or react. Exceptions
  by chat, folder or chat type.
- Hide messages from blocked users.
- **Delayed sending:** a pause before text and media go out.
- **Anonymous mode:** a camera mask and a changed voice in one tap.
- **Spoofing:** show another phone number, open a different profile in place of a chosen one. Both are
  local, on your device only.

### Messages

- **Deleted & edited messages.** Deleted messages stay in the chat, edits keep their previous versions.
  Exceptions, automatic clean-up by age, export and import of the history.
- **Restriction bypass:** copy and screenshot protected chats, keep self-destructing and view-once media,
  reveal spoilers, bypass content restrictions, hide sponsored messages.
- **Sending:** word replacement rules, anti-caps, reply with a quote, anonymous stickers, no "via @bot",
  hide "Send as", send with Return.
- **Translation:** Google, Telegram or the system translator, a translate button on messages, translation
  before sending, text in photos.
- **Menu & gestures:** a custom message menu (forward without author, save to Saved Messages or Photos…),
  double tap to edit, bookmarks.
- **Chat export:** one chat or the whole account as HTML and JSON.

### Security

- **Chat protection:** a passcode or Face ID on chosen chats, a secret folder, chats hidden on screenshots
  and screen recordings.
- **Passcode:** more auto-lock options, lock on every launch, lock now.
- **Accounts:** Face ID when switching accounts, separate settings for every account, copy settings from
  another account.

### Media & calls

- **Voice:** a voice changer with presets and your own voice (pitch, timbre, reverb, echo…), an equalizer,
  transcription of voice and video messages (Telegram's server with Premium, Apple's speech recognition
  without it, on the device when the language has a model), automatic transcription, translation of the
  text.
- **Video messages & camera:** AR masks in video messages and video calls, a mask studio, a photo
  watermark.
- **Calls:** call recording, silent mute, a soundboard, in-call statistics, TCP-only calls, no call rating
  prompts.
- **Downloads & quality:** faster downloads and uploads, large photos, video subtitles from speech
  recognition.

### Appearance

- **Theme & background:** AMOLED, separators, edge fade, an animated GIF background for chats and profiles,
  snowfall.
- **Messages:** fonts (iOS fonts or your own), bubbles, checkmarks, stickers.
- **Chat list:** rows, swipes, avatars, folders.
- **Panels:** tab bar, input field, quick buttons.
- **Icons:** icon packs, a badge under the Dynamic Island.
- **Profile & settings:** user ID, data center, dates, which Settings items are shown.

### More

- **VPN by subscription:** VLESS subscriptions and servers, Telegram goes through your server. The Xray
  core is a separate framework inside the app and is loaded only when the VPN is switched on.
- **Name badges** next to names (GCONNECT).
- **Fake gifts:** gifts on your profile that only you see.
- **Extras:** in-app Safari or another browser, picture in picture for YouTube, IP and api_id in sessions,
  "Recent Actions" and "Administrators" in menus, more mute and cache options, no Premium offers.
- **Ghostgram settings:** language, export and import of all settings, reset.

The interface is in English, Russian, Ukrainian and Arabic.

## Building

You need a Mac with Xcode and Python 3. Bazel is downloaded by `build-system/Make/Make.py` on the first
run.

1. Clone the repository with its submodules:

   ```sh
   git clone --recursive -j8 https://github.com/ichmagmaus111/ghostgram.git
   cd ghostgram
   ```

2. Create the configuration file and fill it in: `api_id` and `api_hash` from
   [my.telegram.org](https://my.telegram.org), your Apple `team_id`, and `bundle_id` if you sign the app
   with your own account.

   ```sh
   cp build-system/ghostgram-configuration.example.json build-system/ghostgram-configuration.json
   ```

3. Simulator build:

   ```sh
   build-system/GGBuild.sh
   ```

   The simulator does not check signatures, but `Make.py` still reads a provisioning profile that matches
   `team_id` and `bundle_id`. Put your profiles into `build-system/ghostgram-codesigning/profiles` or point
   `GG_CODESIGN` at another codesigning folder. Without them the script uses
   `build-system/fake-codesigning`, whose profiles are issued for `ph.telegra.Telegraph` only.

4. Device build (IPA):

   ```sh
   build-system/GGBuildRelease.sh <build number>
   ```

   It needs a distribution certificate (`.p12` with an empty password) in
   `build-system/ghostgram-codesigning/certs` and profiles for the app and its extensions in
   `build-system/ghostgram-codesigning/profiles`. The result is `build-output/ipa/Ghostgram.ipa`.

Both scripts pin Bazel to the Xcode chosen with `xcode-select` (`build-system/GGXcodeConfig.sh`) and apply
the patches from `build-system/GGPatches` to the `rules_apple` and `tgcalls` submodules. The configuration
file, the signing folder and the build output are in `.gitignore`.

### VPN core (optional)

```sh
Ghostgram/Features/Vless/Core/build-core.sh
```

Needs Go 1.26 or newer and the Xcode command line tools; the first run downloads
[Xray-core](https://github.com/XTLS/Xray-core). Without the core the app still builds, and the VPN screen
says that the core is not included.

## Code layout

- `Ghostgram/` — everything Ghostgram adds: `GGCore` (settings, strings, logging), `GGHooks` (the points
  where Ghostgram connects to Telegram's code), `GGSettingsUI` (the menu), `Features/` (the features),
  `Strings/` (translations; `generate.py` builds the string tables, `check.py` checks them).
- The rest of the tree is Telegram iOS. Changes to Telegram's own files are kept small and call into
  `GGHooks`.

## License

Ghostgram is distributed under the [GNU General Public License v2](LICENSE), like the Telegram iOS source
code it is based on. Third-party components keep their own licenses; the list is in the app
(**Settings → Ghostgram → About → Third-Party Components**).

If you build your own app from this code, follow Telegram's
[rules for developers](https://github.com/TelegramMessenger/Telegram-iOS#creating-your-telegram-application):
get your own `api_id`, do not call your app Telegram or use its logo, take care of your users' privacy and
publish your code.
