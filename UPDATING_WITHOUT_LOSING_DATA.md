# Updating Zen Without Losing Playlists

Your playlists and library are stored in the app’s database (SwiftData). They are **kept when you update** as long as the app is not deleted.

## Do this when updating

1. **App Store updates**  
   Use **Update** on Zen in the App Store. Do **not** delete the app first.  
   Data is preserved when you update in place.

2. **Development (Xcode)**  
   Use **Run** (⌘R) to build and install. This installs over the existing app and keeps the database.  
   Do **not** delete the app from the device/simulator before running.

## What clears your data

- **Deleting the app** (e.g. long-press → Remove App) removes all app data, including playlists and the music library.
- **Reinstalling after delete** starts with an empty database.

So: **update in place** (App Store Update or Xcode Run). **Don’t delete the app** if you want to keep playlists and library.

## Optional: backup playlists

If you use the **server browser** (File Sharing):

1. You can **import** playlists by uploading `.m3u` or `.m3u8` files; they’re created from your current library.
2. To back up before an update, export your playlists as `.m3u` from another app or tool and keep those files. After any reinstall, you can re-import them via the server upload page.

## If you already lost playlists

After a reinstall you have to re-import:

1. Re-sync your music (refresh in Library so songs come back).
2. Re-import playlists by uploading `.m3u`/`.m3u8` files via the server browser upload page; they’ll be recreated from the current library.

Future updates done **without** deleting the app will keep your playlists and library.
