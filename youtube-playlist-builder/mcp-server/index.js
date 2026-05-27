#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
const YTDLP = process.env.YTDLP_BIN || "yt-dlp";

try {
  await execFileP(YTDLP, ["--version"], { timeout: 5000 });
} catch (_) {
  console.error(
    "yt-dlp not found on PATH. Run the setup script to install it:\n" +
      "  bash " +
      new URL("./setup.sh", import.meta.url).pathname +
      "\nOr install manually:  brew install yt-dlp"
  );
  process.exit(1);
}

async function resolveTrack(query) {
  const { stdout } = await execFileP(
    YTDLP,
    [
      "--flat-playlist",
      "--skip-download",
      "--no-warnings",
      "--print",
      "%(id)s|%(title)s|%(channel)s",
      `ytsearch1:${query}`,
    ],
    { timeout: 30_000 }
  );
  const line = stdout.split("\n").find((l) => l.includes("|"));
  if (!line) return null;
  const [videoId, title, channel] = line.split("|");
  if (!videoId || videoId.length < 8) return null;
  return { videoId, title: title || "", channel: channel || "" };
}

function buildWatchVideosUrl(videoIds) {
  return `https://www.youtube.com/watch_videos?video_ids=${videoIds.join(",")}`;
}

const server = new Server(
  { name: "youtube-playlist-url", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "build_playlist_url",
      description:
        "Resolve a list of 'Artist - Title' track strings to YouTube video IDs via yt-dlp (no API key, no quota). Returns the IDs plus a watch_videos URL. The skill should hand the comma-joined IDs to the bookmarklet rather than relying on the watch_videos URL (which YouTube has progressively broken). Limit ~50 tracks.",
      inputSchema: {
        type: "object",
        properties: {
          tracks: {
            type: "array",
            items: { type: "string" },
            description: "Ordered list of track query strings, e.g. 'Chemical Brothers Galvanize'.",
            minItems: 1,
            maxItems: 50,
          },
        },
        required: ["tracks"],
      },
    },
    {
      name: "search_video",
      description: "Search YouTube via yt-dlp for a single query and return the top match (video ID, title, channel). Useful for verifying a track or refining a query.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Search query." },
        },
        required: ["query"],
      },
    },
  ],
}));

async function runWithLimit(items, limit, fn) {
  const results = new Array(items.length);
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const idx = i++;
      results[idx] = await fn(items[idx], idx);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => worker())
  );
  return results;
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "search_video") {
    try {
      const match = await resolveTrack(args.query);
      return {
        content: [
          {
            type: "text",
            text: match
              ? JSON.stringify(match, null, 2)
              : `No results for: ${args.query}`,
          },
        ],
      };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `yt-dlp error: ${err.message ?? err}` },
        ],
        isError: true,
      };
    }
  }

  if (name === "build_playlist_url") {
    const tracks = args.tracks;
    // yt-dlp is heavier than a single HTTP request — cap concurrency.
    const results = await runWithLimit(tracks, 4, async (t) => {
      try {
        const m = await resolveTrack(t);
        return { track: t, ...(m ?? { videoId: null }) };
      } catch (err) {
        return { track: t, videoId: null, error: String(err.message ?? err) };
      }
    });
    const resolved = results.filter((r) => r.videoId);
    const unresolved = results.filter((r) => !r.videoId);
    const url = resolved.length
      ? buildWatchVideosUrl(resolved.map((r) => r.videoId))
      : null;
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ url, resolved, unresolved }, null, 2),
        },
      ],
    };
  }

  throw new Error(`Unknown tool: ${name}`);
});

const transport = new StdioServerTransport();
await server.connect(transport);
