"""Independent B layout specification. Composes glyph masks and geometric regions.
No RTL parsing/address generation; every production pixel is compared by the runners.
"""
from pathlib import Path
from PIL import Image
WHITE=0xffffff;INK=0;BLUE=0x2965c0;GRAY=0x808080;LINE=0xc8daf3;PALE=0xedf3fc
ACCENTS=[0xc8daf3,0xbdd2f0,0xb2caec,0xa6c3e9,0x9bbbe5,0x90b3e2,0x84abdf,0x79a3db,0x6e9bd8,0x6294d4,0x578cd1,0x4c84ce,0x407cca,0x3574c7,0x2a6dc3,BLUE]
TINTS=[WHITE,0xfefeff,0xfdfdff,0xfbfdfe,0xfafcfe,0xf9fbfe,0xf8fafe,0xf7f9fe,0xf5f9fd,0xf4f8fd,0xf3f7fd,0xf2f6fd,0xf0f6fc,0xeff5fc,0xeef4fc,PALE]
DIGITS='０１２３４５６７８９'
def rgb(n):return(n>>16,n>>8&255,n&255)
def d3(v,blank=False):return '   ' if not v and blank else ''.join(DIGITS[int(c)] for c in f'{v:03d}')
def d2(v):return ''.join(DIGITS[int(c)] for c in f'{v:02d}')
def fields(s,values):
 for v in values:
  i=s.index('#');j=i
  while j<len(s) and s[j]=='#':j+=1
  s=s[:i]+v+s[j:]
 return s
class Canvas:
 def __init__(self,code,font,bank,base):
  self.im=Image.new('RGB',(640,480),rgb(WHITE));self.base=base;self.mask={};self.edge={};self.bank=bank
  self.phase=15
  for c,i in code.items():
   for plane,target in [(0,self.mask),(16,self.edge)]:
    m=Image.new('L',(16,16));m.putdata([255 if font[i*16+y]>>(plane+15-x)&1 else 0 for y in range(16) for x in range(16)])
    target[c]=m
 def panel(self,b,selected=False,fill=WHITE):
  # 10/23 copy: fill = inside colour of an unselected panel (the current clinic screen uses PALE)
  self.round(b,ACCENTS[self.phase] if selected else LINE)
  self.round((b[0]+2,b[1]+2,b[2]-2,b[3]-2),TINTS[self.phase] if selected else fill)
 def round(self,b,color):
  for yy in range(b[1],b[3]):
   dy=min(yy-b[1],b[3]-1-yy);cut=1 if dy==0 else 0
   self.im.paste(rgb(color),(b[0]+cut,yy,b[2]-cut,yy+1))
 def photo(self,b):
  for yy in range(b[1],b[3]):
   dy=min(yy-b[1],b[3]-1-yy);cut=1 if dy==0 else 0
   self.im.paste(self.base.crop((b[0]+cut,yy,b[2]-cut,yy+1)),(b[0]+cut,yy))
 def put(self,s,x,y,color=INK,scale=1,outline=False):
  for i,c in enumerate(s):
   if c in '#$@':continue
   for masks,col in [(self.edge,WHITE),(self.mask,color)] if outline else [(self.mask,color)]:
    m=masks[c]
    size=round(16*scale)
    if size==24:
     mm=Image.new('L',(24,24));mm.putdata([m.getpixel((xx*2//3,yy*2//3)) for yy in range(24) for xx in range(24)]);m=mm
    elif size!=16:m=m.resize((size,size),Image.Resampling.NEAREST)
    self.im.paste(rgb(col),(x+i*size,y),m)
 def big(self,n,x,y,step=64):
  for i,c in enumerate('---' if n==0 else f'{n:03d}'):
   symbol=10 if c=='-' else int(c)
   for shift,col in [(24,WHITE),(0,ACCENTS[self.phase])]:
    m=Image.new('L',(56,96))
    for yy in range(96):
     row=self.bank[symbol*96+min(yy,63) if symbol==10 else symbol*96+yy]>>shift
     spans=[(row&63,(row>>6)&63),((row>>12)&63,(row>>18)&63)]
     for start,end in spans:
      for xx in range(start,end):m.putpixel((xx,yy),255)
    self.im.paste(rgb(col),(x+i*step,y),m)
 def row(self,y,x0,x1,color):self.im.paste(rgb(color),(x0,y,x1,y+1))
def load_bank(group):
 root=Path(__file__).resolve().parents[2]
 return [int(s,16) for s in (root/f'src/user_source/hdl_source/{group}/ui_digits.hex').read_text().split()]
def render_hall(frames,t,code,font,states,in_rgb,prompt_frames):
 base=Image.new('RGB',(640,480));base.putdata([rgb(in_rgb(x,y)) for y in range(480) for x in range(640)])
 bank=load_bank('display');out=[];timer=pid=scroll=0
 for idx,f in enumerate(frames):
  call,card,help_,vb,vs,bri,con,inv,dup,full,conf,last,lv,issued,waiting=f;u=states[idx];scroll=(scroll+1)%1024
  if inv|dup|full|conf:
   pid=6 if conf else 5 if full else 0 if inv&1 else 1 if inv&0x42 else 2 if inv&4 else 3 if inv&128 else 7 if dup&32 and help_==1 and card==0 else 4
   timer=prompt_frames
  prompt=bool(timer);timer=max(0,timer-1)
  c=Canvas(code,font,bank,base);c.phase=u.get('animation_phase',15)
  c.put(t[0][:4],16,8,scale=2);c.put(t[33+2*u['phy']+u['online']][:14],400,24,GRAY);c.row(49,16,624,LINE)
  if u['ready']:c.photo((16,64,624,302))
  else:c.round((16,64,624,302),PALE)
  if u['thumb']:
   c.im.paste(base.crop((160,64,480,304)),(160,64));c.put(fields(t[32],[d3(n,True) for n in u['history']]),16,302)
  elif u['page']==0:
   c.put(t[1][:4],32,80,outline=True);c.big(call,32,104)
   if call:c.put(t[0][12:18],32,228,outline=True)
   if waiting:c.put(fields(t[12],[d3(call+1)]),368,80,scale=2,outline=True)
   else:c.put(t[12][:3],368,80,scale=2,outline=True);c.put(t[10],464,80,scale=2,outline=True)
   c.put(fields(t[30],[d2(waiting)]),368,132,scale=2,outline=True)
   c.put(fields(t[31],[d3(issued)]),368,176,scale=2,outline=True)
   if u['ready']:
    c.put(fields(t[32],[d3(n,True) for n in u['history']]),32,250,outline=True)
    c.put(t[1][10:15],32,278,outline=True);c.put(t[48+card],112,278,outline=True)
   else:c.put(t[63],16,262)
  elif u['page']==1:
   c.put(t[40][11:16],32,78,scale=2,outline=True);c.put(t[1][:4],448,82,outline=True)
   c.put(d3(call) if call else '－－－',512,82,BLUE,outline=True)
   if waiting:c.put(fields(t[12],[d3(call+1)]),32,120,outline=True)
   else:c.put(t[12][:3],32,120,outline=True);c.put(t[10],80,120,outline=True)
   c.put(fields(t[30],[d2(waiting)]),208,120,outline=True);c.put(fields(t[31],[d3(issued)]),368,120,outline=True)
   for i in range(6):
    x=28+i%3*198;y=156+i//3*64;c.panel((x,y,x+188,y+52),card==i)
    if card==i and c.phase:c.im.paste(rgb(BLUE),(x+4,y+48,x+4+c.phase*12,y+50))
    c.put(t[48+i],x+22,y+14,BLUE if card==i else INK,1.5)
  else:
   c.put(t[1][:4],32,80,BLUE,outline=True);c.put(d3(call) if call else '－－－',96,80,BLUE,outline=True)
   if waiting:c.put(fields(t[12],[d3(call+1)]),32,120,outline=True)
   else:c.put(t[12][:3],32,120,outline=True);c.put(t[10],80,120,outline=True)
   c.put(fields(t[30],[d2(waiting)]),32,156,outline=True);c.put(fields(t[31],[d3(issued)]),32,192,outline=True)
   c.put(fields(t[32],[d3(n,True) for n in u['history']]),16,232,outline=True)
   c.panel((244,80,610,285),True)
   c.im.paste(rgb(BLUE),(260,234,260+c.phase*20+34,236))
   c.put(t[41 if u['pkind']==2 else 40][:4],260,94,GRAY)
   if u['pkind']==2:c.big(u['pnumber'],324,107)
   else:c.put(t[48+u['pcard']],331,150,scale=2)
   c.put(t[42][:11],276,252,BLUE)
  c.panel((16,318,624,408))
  c.put(t[24+last][:4] if lv else t[24][:4],28,330,GRAY)
  c.put(t[48+last] if lv else t[10],92,328)
  c.put(t[13+help_][:10],432,330,BLUE if help_ else GRAY)
  c.row(357,28,612,LINE)
  if not u['busy']:c.put(t[44][:7],28,364)
  elif u['active_kind'] in (1,2):c.put(fields(t[43 if u['active_kind']==1 else 62],[d3(u['active_number'])])[:10],28,364)
  elif u['active_kind']==5:c.put(t[61][:9],28,364)
  else:c.put(t[60],28,364);c.put(t[48+u['active_card']],76,364)
  s=fields(t[45],[DIGITS[u['queued']],DIGITS[u['queued']+u['busy']]])
  c.put(s[:12],352,364,GRAY)
  c.im.paste(base.crop((28,384,156,408)),(28,384))
  vi=7 if vb else vs if vs<=5 else 6;c.put(t[16+vi][:3],176,388,GRAY)
  c.put('图'+DIGITS[1+u['image']] if u['ready'] else t[63][:5],352,388,GRAY)
  hint=t[53+u['notice']] if 0<u['notice']<=6 else t[2+pid] if prompt else t[37+u['page']]
  c.put(hint[:40],0,416,BLUE)
  # The hardware ticker is a 1024px circular strip, advanced exactly once per frame.
  # Render all 64 ticker columns, including those outside the visible strip.
  for x in range(640):
   sx=(x+scroll)%1024;ci=sx//16;bit=sx%16
   ch=t[11][ci] if ci<len(t[11]) else ' '
   for yy in range(16):
    if c.mask[ch].getpixel((bit,yy)):c.im.putpixel((x,440+yy),rgb(BLUE))
    else:c.im.putpixel((x,440+yy),rgb(WHITE))
  bv=[100,75,50,25][bri];cv=[100,125,150,75][con]
  foot=fields(t[46 if u['auto'] else 47],[str(bv).translate(str.maketrans('0123456789',DIGITS)).rjust(3),str(cv).translate(str.maketrans('0123456789',DIGITS)).rjust(3),DIGITS[1+u['image']],('０' if u['error']==0 else 'E')+('０１２３４５６７８９ABCDEF'[u['error']])])
  c.put(foot[:40],0,464,GRAY)
  out.append([(r<<16)|(g<<8)|b for r,g,b in c.im.getdata()])
 return out

def render_clinic(frames,t,code,font,in_rgb,animation_phases=None,pulse_phases=None):
 base=Image.new('RGB',(640,480));base.putdata([rgb(in_rgb(x,y)) for y in range(480) for x in range(640)])
 bank=load_bank('clinic');out=[]
 for fi,(call,issued,waiting,last,lv,help_,up,alarm,op,ops) in enumerate(frames):
  phase=15 if animation_phases is None else animation_phases[fi]
  hp=15 if pulse_phases is None else pulse_phases[fi]
  c=Canvas(code,font,bank,base);c.phase=phase;c.put(t[0][:5],16,8,scale=2);c.put(t[17 if up else 18][:4],512,24,GRAY);c.row(49,16,624,LINE)
  c.im.paste(rgb(BLUE),(16,46,112,49))      # 10/18 title accent bar
  c.panel((16,64,624,258),fill=PALE)
  if help_==1:
   # Same surface, blue pending perimeter; no false "no help" during blink-off.
   c.round((16,64,624,258),ACCENTS[hp]);c.round((18,66,622,256),PALE)
  c.im.paste(rgb(LINE),(424,88,425,236))
  c.put(t[3+help_][:10],32,82,BLUE if help_ else GRAY)
  c.put(t[18 if not up else (6 if alarm else 37) if help_==1 else 3+help_][:10],32,120,scale=2)
  c.put(t[10][:4],32,180,GRAY);c.put(t[10+last if lv else 16][5:11],32,210,scale=2)
  c.put(t[38 if up else 39][:4],448,96,GRAY);c.phase=15;c.big(call,446,119,56);c.phase=phase
  c.put(fields(t[7],[d3(call+1)]) if waiting else t[20],32,282)
  c.put(fields(t[8],[d2(waiting)]),240,282);c.put(fields(t[9],[d3(issued)]),448,282)
  c.row(317,16,624,LINE)
  c.put(t[36 if not op or not ops or ops>5 else 21+5*(op-1)+ops-1][:38],16,338,ACCENTS[phase] if op and ops==2 else GRAY if not op or not ops or ops>5 else INK)
  for i,(key,word) in enumerate([(t[19][:4],t[19][5:9]),(t[19][11:15],t[19][16:18]),(t[19][20:24],t[19][25:29])]):
   x=16+i*208;c.panel((x,376,x+192,454),help_==1 and i==2,fill=PALE);c.put(key,x+16,390,GRAY);c.put(word,x+16,416,BLUE if help_==1 and i==2 else INK,2)
  out.append([(r<<16)|(g<<8)|b for r,g,b in c.im.getdata()])
 return out
