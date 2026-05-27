# YouTube Bulk-Add Bookmarklet

A one-time-install browser bookmark that adds a batch of videos to one of your YouTube playlists using your existing logged-in session. No OAuth, no API key, no extension.

## How it works

The bookmarklet runs JavaScript inside an open `youtube.com` tab. It reads the page's `ytcfg` (which contains the same Innertube API key and context the YouTube web UI uses), computes a `SAPISIDHASH` from your session cookies, and POSTs an `ACTION_ADD_VIDEO` request per video ID to YouTube's internal `/youtubei/v1/browse/edit_playlist` endpoint — the same endpoint the **Save** button calls.

Because it uses your existing session, you must be signed in. Nothing is sent anywhere except to youtube.com.

## One-time install (Firefox)

1. Right-click the bookmarks toolbar → **New Bookmark**.
2. **Name**: `YT: Add to Playlist` (or whatever).
3. **URL**: paste the entire contents of `add-to-playlist.bookmarklet.txt` (one long line starting with `javascript:`).
4. Save.

If Firefox warns about a `javascript:` URL, allow it. You can also drag the link directly to the bookmark bar if you create an HTML file containing `<a href="javascript:...">Install</a>`.

## Per-playlist usage

1. In YouTube, create the destination playlist (one time):
   - Library → **+ New playlist** → name it → Create.
   - Open the playlist. Copy its ID from the URL — the `list=PL...` portion (just the `PL...` part, not the `list=` prefix).
2. In Claude, build the tracklist with `/youtube-playlist-builder:playlist`. The MCP returns a comma-separated list of video IDs.
3. With a YouTube tab focused (any youtube.com page works), click the bookmarklet.
4. First prompt: paste the playlist ID. Second prompt: paste the video IDs (comma-separated). Click OK.
5. An alert confirms how many were added, or reports an error.

You can re-run the bookmarklet on the same playlist to append more videos later.

## Updating the bookmarklet

If you change `add-to-playlist.js`, regenerate the bookmark URL:

```
node build.mjs
```

Then replace the bookmark's URL with the new contents of `add-to-playlist.bookmarklet.txt`.

## Limitations & failure modes

- **Session-bound**: if you sign out of YouTube, the bookmarklet stops working until you sign back in.
- **YouTube can change the internal API at any time**: this is undocumented and could break without warning. The fix is usually small (header name, payload shape) but is on you to maintain.
- **Multiple Google accounts**: the `X-Goog-AuthUser: 0` header targets the first account. If your YouTube channel lives under a non-primary account, edit the JS to use the right index.
- **Region-locked or private videos** will be added (the API accepts them) but won't play.
- **Rate limiting**: adding ~30 videos in one batched request has been reliable in testing. If you hit rate limits with larger batches, split into chunks of 25.

## Privacy / safety

- Only sends requests to `https://www.youtube.com`.
- No analytics, no third-party domains, no external scripts.
- You can read the entire source in `add-to-playlist.js` before installing.
