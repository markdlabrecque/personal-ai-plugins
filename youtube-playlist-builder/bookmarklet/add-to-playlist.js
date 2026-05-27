// Add a batch of videos to an existing YouTube playlist.
// Run on any youtube.com page while signed in. Piggybacks on session cookies via
// YouTube's internal Innertube API — no OAuth, no API key.
(async () => {
  try {
    if (!location.hostname.includes("youtube.com")) {
      alert("Open this bookmarklet on a youtube.com tab.");
      return;
    }
    const cfg = window.ytcfg && window.ytcfg.data_;
    if (!cfg || !cfg.INNERTUBE_API_KEY) {
      alert("ytcfg not found. Reload the YouTube tab and retry.");
      return;
    }

    const rawPlaylist = prompt("Playlist ID or URL:");
    if (!rawPlaylist) return;
    // Accept full URL, "list=..." param, or bare ID.
    const playlistId =
      (rawPlaylist.match(/[?&]list=([^&\s]+)/) || [])[1] ||
      rawPlaylist.trim();

    // Try clipboard first (avoids terminal copy/paste wrap artifacts);
    // fall back to a prompt if the read is denied or empty.
    let idsRaw = "";
    try {
      idsRaw = await navigator.clipboard.readText();
    } catch (_) {
      // permission denied — fall through
    }
    if (!idsRaw || !idsRaw.match(/[,\n\s]/) === false && idsRaw.length < 11) {
      idsRaw = prompt("Video IDs (comma- or newline-separated):") || "";
    }
    const videoIds = idsRaw
      .split(/[,\n]/)
      .map((s) => s.replace(/\s+/g, ""))
      .filter((s) => /^[\w-]{11}$/.test(s));
    if (!videoIds.length) {
      alert(
        "No valid 11-char video IDs found on clipboard.\nClipboard preview:\n" +
          idsRaw.slice(0, 120)
      );
      return;
    }

    const preview =
      videoIds.length <= 4
        ? videoIds.join(", ")
        : videoIds.slice(0, 2).join(", ") +
          ", … (" +
          (videoIds.length - 4) +
          " more) … , " +
          videoIds.slice(-2).join(", ");
    if (
      !confirm(
        "Add " +
          videoIds.length +
          " videos to " +
          playlistId +
          "?\n\n" +
          preview
      )
    ) {
      return;
    }

    const sapisid =
      (document.cookie.match(/(?:^|; )SAPISID=([^;]+)/) || [])[1] ||
      (document.cookie.match(/(?:^|; )__Secure-3PAPISID=([^;]+)/) || [])[1];
    if (!sapisid) {
      alert("SAPISID cookie missing. Are you signed in to YouTube?");
      return;
    }

    const origin = "https://www.youtube.com";
    const ts = Math.floor(Date.now() / 1000);
    const buf = await crypto.subtle.digest(
      "SHA-1",
      new TextEncoder().encode(ts + " " + sapisid + " " + origin)
    );
    const hex = Array.from(new Uint8Array(buf))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    const auth = "SAPISIDHASH " + ts + "_" + hex;

    const clientName = (cfg.INNERTUBE_CONTEXT_CLIENT_NAME || 1).toString();
    const clientVersion = cfg.INNERTUBE_CLIENT_VERSION || "2.0";
    const headers = {
      "Content-Type": "application/json",
      Authorization: auth,
      "X-Origin": origin,
      "X-Goog-AuthUser": "0",
      "X-YouTube-Client-Name": clientName,
      "X-YouTube-Client-Version": clientVersion,
    };

    // Fetch existing video IDs in the playlist so we can skip them.
    // Note: only reads the first page of the playlist (~100 videos), which
    // is plenty for the playlist sizes this skill builds.
    const existing = new Set();
    try {
      const browseRes = await fetch(
        origin +
          "/youtubei/v1/browse?key=" +
          cfg.INNERTUBE_API_KEY +
          "&prettyPrint=false",
        {
          method: "POST",
          credentials: "include",
          headers,
          body: JSON.stringify({
            context: cfg.INNERTUBE_CONTEXT,
            browseId: "VL" + playlistId,
          }),
        }
      );
      const browseData = await browseRes.json().catch(() => null);
      const walk = (node) => {
        if (!node || typeof node !== "object") return;
        const r = node.playlistVideoRenderer;
        if (r && r.videoId) existing.add(r.videoId);
        if (Array.isArray(node)) node.forEach(walk);
        else for (const k in node) walk(node[k]);
      };
      walk(browseData);
    } catch (_) {
      // Non-fatal — proceed without dedupe.
    }

    const toAdd = videoIds.filter((id) => !existing.has(id));
    const preSkipped = videoIds.length - toAdd.length;
    if (!toAdd.length) {
      alert(
        "All " +
          videoIds.length +
          " videos are already in playlist " +
          playlistId +
          ". Nothing to add."
      );
      return;
    }

    let added = 0;
    const failures = [];
    for (const id of toAdd) {
      const body = {
        context: cfg.INNERTUBE_CONTEXT,
        playlistId,
        actions: [
          {
            action: "ACTION_ADD_VIDEO",
            addedVideoId: id,
          },
        ],
      };
      let res, data;
      try {
        res = await fetch(
          origin +
            "/youtubei/v1/browse/edit_playlist?key=" +
            cfg.INNERTUBE_API_KEY +
            "&prettyPrint=false",
          {
            method: "POST",
            credentials: "include",
            headers,
            body: JSON.stringify(body),
          }
        );
        data = await res.json().catch(() => ({}));
      } catch (e) {
        failures.push({ id, status: 0, reason: e.message || String(e) });
        continue;
      }
      if (res.ok && data.status === "STATUS_SUCCEEDED") {
        added++;
      } else {
        failures.push({
          id,
          status: res.status,
          reason: data.error?.message || data.status || "unknown",
        });
      }
    }

    const lines = [
      "Added " + added + " of " + toAdd.length + " new videos.",
    ];
    if (preSkipped) {
      lines.push("Skipped " + preSkipped + " already in playlist.");
    }
    if (failures.length) {
      lines.push("Errors (" + failures.length + "):");
      for (const f of failures.slice(0, 5)) {
        lines.push("  " + f.id + " — " + f.status + " " + f.reason);
      }
      if (failures.length > 5) lines.push("  …");
    }
    alert(lines.join("\n"));
  } catch (e) {
    alert("Error: " + (e && e.message ? e.message : e));
  }
})();
