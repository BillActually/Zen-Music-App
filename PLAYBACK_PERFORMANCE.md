# Playback / song-switch performance

## What’s in place now

- **Preload cache**: The next ~10 songs (manual queue + list queue) are preloaded in the background. Tapping one of those uses the cached item → **instant** switch.
- **Cache miss**: When you tap a song that wasn’t preloaded, we **create the item on the main thread** and apply immediately. You get a short UI freeze (~0.2–0.5s) then audio starts with no extra async delay. Tradeoff: brief freeze vs. no “wait then play” feeling.

## If it still feels slow, things you can try

### 1. Profile where time goes

Use **Instruments → Time Profiler** (or add `CFAbsoluteTimeGetCurrent()` prints) around:

- Tap → `play()` → `loadAndPlay` → start/end of `makePlayerItem` → `applyPlayerItemAndStart` → `play()`.

See whether most time is in:

- `resolvePlayableURL` / filesystem
- `startAccessingSecurityScopedResource()`
- `AVURLAsset` / `AVPlayerItem` creation
- Or something else (e.g. SwiftUI, observers)

Then we can target that.

### 2. Preload based on visible rows

Right now we only preload “next in queue” (manual + list). If you usually tap **whatever is on screen**, we could preload **only the visible list**:

- Library (or list) view reports “these song IDs are visible” (e.g. via `onAppear` / scroll).
- Player has something like `prepareForPlayback(visibleSongIDs: [URL])` and preloads only those (e.g. 10–15 items).
- Tapping any visible row is then much more likely to be a cache hit.

Requires wiring the list view to the player (callback or binding).

### 3. Cache resolved file paths

If profiling shows time in `resolvePlayableURL` / path resolution, we could cache “song.id → resolved file path” (and invalidate when library changes) so we don’t hit the filesystem on every switch.

### 4. Reduce security-scoped work

`startAccessingSecurityScopedResource()` can be slow. If files are in a known location (e.g. app Documents), we might be able to avoid it in some cases or cache the fact that we already have access. Depends on your sandbox / entitlements.

### 5. “Instant” mode in Settings

Add a setting, e.g. **“Prefer instant switch”**:

- **On**: Keep current behavior (preload + sync create on miss; accept brief freeze on miss).
- **Off**: Always create on a background thread (no freeze, but audio starts later).

So you can choose freeze vs. delay per device/preference.

### 6. Device / storage

On slow storage (e.g. old device, or files on network/cloud), file open + first read will dominate. Moving music to local, fast storage (if possible) often helps more than code changes.

---

**Summary**: We switched to **sync create on cache miss** so that when a song isn’t preloaded, audio starts as soon as the short block finishes. If it’s still not fast enough, profiling (1) and visible-list preload (2) are the next high-value steps.
