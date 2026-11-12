#!/usr/bin/env python3
"""Screenshot the explorer pages of the 2026-11-12 cross-chain run (proof that outlives a testnet reset),
plus a contact sheet to check them at a glance.  python3 -I capture.py [name ...]  → evidence/<name>.png"""
import json, pathlib, sys
from PIL import Image
from playwright.sync_api import sync_playwright

OUT = pathlib.Path(__file__).resolve().parent / "evidence"; OUT.mkdir(exist_ok=True)
LASNA, SEP, SEPB = "https://lasna.reactscan.net", "https://sepolia.etherscan.io", "https://eth-sepolia.blockscout.com"
PAGES = {
    "lasna-watch": f"{LASNA}/address/0xA89110Cbc363ea207292FCBF97bb7c550c661510",
    "lasna-watch-callbacks": f"{LASNA}/address/0xA89110Cbc363ea207292FCBF97bb7c550c661510|CALLBACKS [",
    "lasna-watch-exec": f"{LASNA}/address/0xA89110Cbc363ea207292FCBF97bb7c550c661510|REACTIVE EXECUTIONS [",
    "lasna-warn": f"{LASNA}/tx/0xcde0f0e0a70f1a05039c09328d2e43ece115f669eae0006abdd08ee2a84520f6",
    "lasna-cancel": f"{LASNA}/tx/0xfef707ed0386260d1df376f8ba2bb7bc734f8c26d403e3fb191a3afff090a8d0",
    "lasna-release": f"{LASNA}/tx/0xc3022796441caa1ec08d8e0944af04c298f7e682b4c0e7abc5afe08f26161b99",
    "sep-checkin": f"{SEP}/tx/0xb80d3e5581c487ed598ac21c47413ede5de41ae54c168a1c6a40b884fda3e7ac",
    "sep-vault": f"{SEP}/address/0x97d5056B5f86f35A5E5dCc400E74bA81985BF13C",
    "sep-release": f"{SEP}/tx/0x9fa6742ba9887e60633cd8d7538e0e9626c9c12293ff7106d3b230a92b732278",
    "sep-distribute": f"{SEP}/tx/0x8cf46291d4699eafe5f099e787efa3ee85a07f6baac101358940686d843c8442",
    "sepb-distribute": f"{SEPB}/tx/0x8cf46291d4699eafe5f099e787efa3ee85a07f6baac101358940686d843c8442",
    "sepb-vault": f"{SEPB}/address/0x97d5056B5f86f35A5E5dCc400E74bA81985BF13C",
}
# text to highlight in the video: its boxes, in screenshot pixels, go to evidence/boxes.json
TARGETS = {"lasna-watch-callbacks": ["CONFIRMED", "CALLBACKS ["], "lasna-cancel": ["CONFIRMED", "BLOCK TIMESTAMP"],
           "lasna-warn": ["CONFIRMED"], "sep-checkin": ["Check In", "Nov-12-2026"], "sep-release": ["Deliver Callback"],
           "sep-distribute": ["666.6666", "333.3333", "Distribute"]}
names = sys.argv[1:] or list(PAGES)
BOXES = OUT / "boxes.json"
boxes = json.loads(BOXES.read_text()) if BOXES.exists() else {}
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 1600, "height": 900}, device_scale_factor=1.2, color_scheme="light",
                        user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
                                   "Chrome/142.0.0.0 Safari/537.36")
    for n in names:
        pg = ctx.new_page()
        try:
            url, _, click = PAGES[n].partition("|")              # "url|text" = click that tab before the shot
            pg.goto(url, wait_until="domcontentloaded", timeout=45000)
            pg.wait_for_timeout(9000)
            for txt in [click, "Got it!"]:                         # the tab, then Etherscan's cookie banner
                loc = pg.get_by_text(txt).first
                if txt and loc.count() and loc.is_visible():         # hidden once the banner was accepted
                    loc.click(); pg.wait_for_timeout(2500)
            pg.screenshot(path=str(OUT / f"{n}.png"))
            pg.screenshot(path=str(OUT / f"{n}-full.png"), full_page=True)   # the whole page, to pan over in the video
            found = {}
            for txt in TARGETS.get(n, []):
                bb = [pg.get_by_text(txt).nth(i).bounding_box() for i in range(pg.get_by_text(txt).count())]
                found[txt] = [[round(v * 1.2) for v in (b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"])]
                              for b in bb if b and b["width"] > 0]
            boxes[n] = found
            print(n, "ok", pg.title()[:80], {k: len(v) for k, v in found.items()})
        except Exception as e:
            print(n, "FAILED", str(e).splitlines()[0][:120])
        pg.close()
    b.close()
BOXES.write_text(json.dumps(boxes, indent=1))

shots = [OUT / f"{n}.png" for n in names if (OUT / f"{n}.png").exists()]
if shots:
    tw, th, cols = 640, 360, 3
    sheet = Image.new("RGB", (tw * cols, th * ((len(shots) + cols - 1) // cols)), "white")
    for i, s in enumerate(shots):
        sheet.paste(Image.open(s).convert("RGB").resize((tw, th)), ((i % cols) * tw, (i // cols) * th))
    sheet.save(OUT / "_sheet.png")
