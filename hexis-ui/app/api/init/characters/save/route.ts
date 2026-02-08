import { mkdir, writeFile } from "fs/promises";
import path from "path";
import os from "os";

export const runtime = "nodejs";

const USER_CHARACTERS_DIR = path.join(os.homedir(), ".hexis", "characters");

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { card, filename, portrait } = body;

    if (!card || typeof card !== "object") {
      return Response.json({ error: "Missing or invalid card data" }, { status: 400 });
    }

    // Validate basic chara_card_v2 structure
    if (!card.data || typeof card.data !== "object") {
      return Response.json({ error: "Invalid card: missing 'data' object" }, { status: 400 });
    }

    // Determine filename
    const hexisExt = card.data?.extensions?.hexis ?? {};
    const cardName = hexisExt.name ?? card.data.name ?? "custom";
    const safeName = (filename ?? `${cardName.toLowerCase().replace(/[^a-z0-9_-]/g, "_")}.json`)
      .replace(/[^a-zA-Z0-9_.-]/g, "_");

    if (!safeName.endsWith(".json")) {
      return Response.json({ error: "Filename must end with .json" }, { status: 400 });
    }

    // Ensure user dir exists
    await mkdir(USER_CHARACTERS_DIR, { recursive: true });

    // Write card JSON
    const destPath = path.join(USER_CHARACTERS_DIR, safeName);
    await writeFile(destPath, JSON.stringify(card, null, 2), "utf-8");

    // Write portrait if provided (base64)
    if (portrait && typeof portrait === "string") {
      const imgName = safeName.replace(/\.json$/, ".jpg");
      const imgPath = path.join(USER_CHARACTERS_DIR, imgName);
      const buffer = Buffer.from(portrait, "base64");
      await writeFile(imgPath, buffer);
    }

    return Response.json({ filename: safeName, path: destPath });
  } catch (err: any) {
    return Response.json({ error: err.message ?? "Failed to save character" }, { status: 500 });
  }
}
