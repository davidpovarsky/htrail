from pathlib import Path
import json
from PIL import Image,ImageOps,ImageDraw
root=Path(__file__).resolve().parent
d=json.loads((root/'.data/manifest.json').read_text())
rows=[r for r in d['rows'] if r['source']=='wikipedia']
out=root/'.data/audit';out.mkdir(exist_ok=True)
for page in range((len(rows)+29)//30):
 batch=rows[page*30:(page+1)*30]
 canvas=Image.new('RGB',(960,1200),'white');draw=ImageDraw.Draw(canvas)
 for i,r in enumerate(batch):
  x=(i%6)*160;y=(i//6)*240
  im=ImageOps.contain(Image.open(root/'.data'/r['path']).convert('RGB'),(156,202))
  canvas.paste(im,(x+(156-im.width)//2,y))
  draw.text((x+2,y+204),str(page*30+i)+' '+r['id'],fill='black')
  draw.text((x+2,y+220),r['expected']+' '+r.get('subject','')[:19],fill='black')
 canvas.save(out/f'wiki-{page}.jpg',quality=88)
(out/'index.json').write_text(json.dumps(rows,indent=2))
print(json.dumps({'pages':(len(rows)+29)//30,'count':len(rows)}))
