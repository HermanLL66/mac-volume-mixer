"""Create deterministic product graphics and encode native SwiftUI preview frames.

Requires Pillow. Run render-showcase.sh first. The animation uses explicitly
labeled sample data; it is not a recording of real audio or third-party apps.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/assets"
OUT.mkdir(parents=True, exist_ok=True)
TEAL = "#197b73"
INK = "#123b37"
MINT = "#bcebd7"
WHITE = "#f8fcfa"
REGULAR = "/System/Library/Fonts/Supplemental/Arial.ttf"
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else REGULAR, size)

def text(draw, xy, value, size, fill, bold=False):
    draw.text(xy, value, font=font(size, bold), fill=fill)

def logo(draw, x, y, scale=1):
    draw.rounded_rectangle((x,y,x+76*scale,y+76*scale),radius=20*scale,fill=TEAL)
    for index, offset in enumerate((27,47,34)):
        line_y=y+(22+16*index)*scale
        draw.line((x+16*scale,line_y,x+60*scale,line_y),fill=WHITE,width=max(1,int(2*scale)))
        cx=x+offset*scale
        draw.ellipse((cx-4*scale,line_y-4*scale,cx+4*scale,line_y+4*scale),fill=TEAL,outline=WHITE,width=max(1,int(2*scale)))

cover = Image.new("RGB", (1280,640), INK)
d = ImageDraw.Draw(cover)
d.ellipse((900,-260,1510,350),fill="#194b44")
d.ellipse((1000,430,1480,910),fill="#194b44")
logo(d,64,56)
text(d,(158,64),"Volume Mixer",42,WHITE,True)
text(d,(160,116),"FOR macOS",17,MINT,True)
text(d,(64,208),"Every app.",76,WHITE,True)
text(d,(64,293),"Your volume.",76,MINT,True)
text(d,(68,405),"Independent volume and mute.",28,WHITE)
text(d,(68,448),"Free. Open source. On your Mac.",25,"#b5d4c8")
text(d,(68,568),"github.com/HermanLL66/mac-volume-mixer",20,"#b5d4c8")
# A graphic control motif, not a fabricated application screenshot.
for index, knob in enumerate((0.28,0.76,0.5)):
    x=880+index*104
    d.rounded_rectangle((x,199,x+12,464),radius=6,fill="#39675c")
    cy=int(450-235*knob)
    d.rounded_rectangle((x,cy,x+12,464),radius=6,fill=MINT)
    d.ellipse((x-18,cy-18,x+30,cy+30),fill=WHITE)
cover.save(OUT/"social-preview.png",optimize=True)

download_svg='''<svg xmlns="http://www.w3.org/2000/svg" width="360" height="72" viewBox="0 0 360 72" role="img" aria-label="Download for Apple Silicon, macOS 14.4 or later"><rect width="360" height="72" rx="15" fill="#197b73"/><path d="M32 22v20m-7-7 7 7 7-7M23 48h18" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/><g fill="#fff" font-family="Arial, sans-serif"><text x="59" y="31" font-size="18" font-weight="700">Download for Apple Silicon</text><text x="59" y="53" font-size="13">macOS 14.4+ · ZIP · Early release</text></g></svg>'''
(OUT/"download.svg").write_text(download_svg)

setup=Image.new("RGB",(1280,400),"#f1f7f3")
d=ImageDraw.Draw(setup)
text(d,(48,30),"A few steps to your own mix",34,INK,True)
cards=[("1","Download & move","Extract the ZIP, then move", "Volume Mixer.app to Applications."),
       ("2","Allow audio access","Click Enable and allow", "system audio access in macOS."),
       ("3","Choose your mix","Play audio, adjust a slider,", "or mute one app at a time.")]
for index,(number,title,line1,line2) in enumerate(cards):
    x=48+index*408
    d.rounded_rectangle((x,102,x+384,320),radius=20,fill="white")
    d.ellipse((x+24,126,x+68,170),fill=TEAL)
    text(d,(x+39,134),number,21,"white",True)
    text(d,(x+24,195),title,24,INK,True)
    text(d,(x+24,242),line1,18,"#4b655e")
    text(d,(x+24,270),line2,18,"#4b655e")
text(d,(48,350),"Setup illustration. System labels vary by macOS version. Initial release is not notarized.",17,"#59736a")
setup.save(OUT/"quick-start.png",optimize=True)

frames = sorted((ROOT/".build/showcase/frames").glob("*.png"))
if len(frames)!=4:
    raise SystemExit("Run ./Tools/render-showcase.sh before creating the animation.")
images=[Image.open(path).convert("RGB") for path in frames]
images[1].save(OUT/"interface-preview.png",optimize=True)
images[0].save(OUT/"interface-demo.gif",save_all=True,append_images=images[1:],duration=[3000,4000,4000,4000],loop=0,optimize=True)
for path in sorted(OUT.iterdir()):
    print(path.relative_to(ROOT),path.stat().st_size)
