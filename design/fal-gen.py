# Text-to-image with Nano Banana Pro on fal; usage: fal-gen.py outprefix "prompt" [n]
import json, os, sys, urllib.request
out, prompt = sys.argv[1], sys.argv[2]; n = int(sys.argv[3]) if len(sys.argv) > 3 else 1
body = json.dumps({"prompt": prompt, "num_images": n, "aspect_ratio": "3:2", "resolution": "2K", "output_format": "png"}).encode()
key = os.environ.get("FAL_KEY") or os.environ["FAL_API_KEY"]
req = urllib.request.Request("https://fal.run/fal-ai/nano-banana-pro", data=body, headers={"Authorization": "Key " + key, "Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=300))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code} {e.read()[:400]!r}")
for i, im in enumerate(r["images"]):
    urllib.request.urlretrieve(im["url"], f"{out}-{i}.png"); print(f"{out}-{i}.png")
