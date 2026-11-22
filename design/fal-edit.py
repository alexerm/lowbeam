# Edits one approved frame with Nano Banana Pro on fal; usage: fal-edit.py in.png out.png "prompt"
import base64, json, os, sys, urllib.request
src, out, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
uri = "data:image/png;base64," + base64.b64encode(open(src, "rb").read()).decode()
body = json.dumps({"prompt": prompt, "image_urls": [uri], "num_images": 1, "aspect_ratio": "3:2", "resolution": "2K", "output_format": "png"}).encode()
key = os.environ.get("FAL_KEY") or os.environ["FAL_API_KEY"]
req = urllib.request.Request("https://fal.run/fal-ai/nano-banana-pro/edit", data=body, headers={"Authorization": "Key " + key, "Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=300))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code} {e.read()[:400]!r}")
urllib.request.urlretrieve(r["images"][0]["url"], out)
print(out, r.get("description", "")[:200])
