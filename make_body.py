import base64, json, sys
img = base64.b64encode(open("shot.jpg", "rb").read()).decode()
prompt = 'Find the Apple logo menu in the top-left corner of this screenshot. Reply with only JSON: {"box_2d": [ymin, xmin, ymax, xmax]} normalized 0-1000.'
print(json.dumps({"model": sys.argv[1], "contents": [{"role": "user", "parts": [{"inlineData": {"mimeType": "image/jpeg", "data": img}}, {"text": prompt}]}], "generationConfig": {"maxOutputTokens": 2048, "responseMimeType": "application/json"}}))
