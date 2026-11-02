#!/usr/bin/env python3
"""Draws the Kids mode + Soft theme mocks as SVG. Render: rsvg-convert -o x.png x.svg"""
import os
OUT=os.path.join(os.path.dirname(__file__),'../../docs/design/mocks')
F="font-family:'Atkinson Hyperlegible Next'"
NAVY='#0F2338'; INK2='#45596E'; BG='#EEF5FC'; CARD='#FFFFFF'; FILL='#DCEBF8'; LINE='#D3E0EE'; BABY='#A9D4F5'
KID={'sky':('#4FB4F7','#2C8FD6'),'leaf':('#4CC968','#2FA34C'),'sun':('#FFD23F','#E8B400'),
     'tan':('#FF9B3F','#E87A1C'),'berry':('#FF6F7D','#E04A5C'),'bubble':('#F58BC0','#D9619E')}
def T(x,y,s,txt,size,w=700,fill=NAVY,anchor='start'):
    return f'<text x="{x}" y="{y}" style="{F};font-size:{size}px;font-weight:{w}" fill="{fill}" text-anchor="{anchor}">{txt}</text>'
def star(cx,cy,r,fill='#FFC83D',edge=NAVY,sw=2.5):
    import math
    pts=[]
    for i in range(10):
        a=-math.pi/2+i*math.pi/5; rr=r if i%2==0 else r*0.46
        pts.append(f'{cx+rr*math.cos(a):.1f},{cy+rr*math.sin(a):.1f}')
    return f'<polygon points="{" ".join(pts)}" fill="{fill}" stroke="{edge}" stroke-width="{sw}" stroke-linejoin="round"/>'
def check(cx,cy,s,col=NAVY,w=None):
    w=w or s*0.16
    return f'<path d="M{cx-s*.38},{cy} L{cx-s*.1},{cy+s*.28} L{cx+s*.42},{cy-s*.3}" fill="none" stroke="{col}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'
# Pictograms: simple geometric, navy, drawn in a 40x40 box centered at (cx,cy) scaled by k.
def picto(kind,cx,cy,k=1,col=NAVY):
    g=f'<g transform="translate({cx},{cy}) scale({k})" fill="none" stroke="{col}" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round">'
    d={'bed':'<rect x="-18" y="-2" width="36" height="12" rx="3"/><path d="M-18,10 v6 M18,10 v6 M-18,-2 v-12"/><rect x="-14" y="-10" width="11" height="8" rx="3"/>',
       'tooth':'<path d="M-12,-14 c6,-4 8,2 12,0 c4,2 6,-4 12,0 c4,6 0,14 -3,26 c-2,4 -5,2 -5,-4 c0,-6 -2,-8 -4,-8 c-2,0 -4,2 -4,8 c0,6 -3,8 -5,4 c-3,-12 -7,-20 -3,-26z"/>',
       'plate':'<circle cx="0" cy="0" r="15"/><circle cx="0" cy="0" r="8"/><path d="M-22,-14 v28 M22,-14 v8 c0,4 -4,4 -4,0 v-8 M22,-6 v20"/>',
       'paw':'<ellipse cx="0" cy="7" rx="10" ry="8"/><circle cx="-12" cy="-6" r="4"/><circle cx="-4" cy="-13" r="4"/><circle cx="5" cy="-13" r="4"/><circle cx="13" cy="-6" r="4"/>',
       'bag':'<rect x="-14" y="-10" width="28" height="26" rx="6"/><path d="M-7,-10 v-4 a7,7 0 0 1 14,0 v4 M-14,2 h28"/>',
       'book':'<path d="M0,-12 c-6,-4 -14,-4 -20,-2 v26 c6,-2 14,-2 20,2 c6,-4 14,-4 20,-2 v-26 c-6,-2 -14,-2 -20,2z M0,-12 v26"/>',
       'toys':'<rect x="-18" y="-4" width="16" height="16" rx="3"/><circle cx="10" cy="4" r="8"/><path d="M-12,-4 l4,-10 l4,10"/>',
       'plant':'<path d="M-10,6 h20 l-3,12 h-14z M0,6 v-10 M0,-4 c-10,0 -12,-8 -12,-12 c6,0 12,4 12,12 c0,-8 6,-12 12,-12 c0,4 -2,12 -12,12"/>',
       'ball':'<circle cx="0" cy="0" r="15"/><path d="M-15,0 h30 M0,-15 c-8,8 -8,22 0,30 M0,-15 c8,8 8,22 0,30"/>',
       'tooth2':'','speaker':'<path d="M-16,-6 h8 l10,-9 v30 l-10,-9 h-8z M8,-6 c4,4 4,8 0,12 M13,-11 c7,7 7,15 0,22"/>',
       'music':'<path d="M-6,10 v-24 l18,-4 v24"/><circle cx="-10" cy="10" r="5"/><circle cx="8" cy="6" r="5"/>',
       'car':'<path d="M-18,6 v-6 l5,-10 h26 l5,10 v6z M-18,6 v5 M18,6 v5"/><circle cx="-10" cy="8" r="3"/><circle cx="10" cy="8" r="3"/>'}[kind]
    return g+d+'</g>'
def chunky(x,y,w,h,r,face,lip,lipd=6):
    return f'<rect x="{x}" y="{y+lipd}" width="{w}" height="{h}" rx="{r}" fill="{lip}"/><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{face}"/>'
def avatar(cx,cy,r,col,initial):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{col}"/><circle cx="{cx}" cy="{cy}" r="{r-4}" fill="none" stroke="#FFFFFF" stroke-width="3"/>'
            + T(cx,cy+r*0.36,0,initial,r*1.0,800,NAVY,'middle'))
def save(name,w,h,body,bg=BG):
    svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><rect width="{w}" height="{h}" fill="{bg}"/>{body}</svg>'
    open(os.path.join(OUT,name+'.svg'),'w').write(svg)

# ---------- 1. Kid chore board, phone 390x844 ----------
def kid_phone():
    b=[]; sky,skyl=KID['sky']
    b.append(T(24,58,0,'9:41',15,700))
    # top nav: avatar + name left, Grown-ups right
    b.append(avatar(52,112,28,sky,'L'))
    b.append(T(92,104,0,'Hi, Leo',30,800)); b.append(T(92,128,0,'Tuesday',16,400,INK2))
    b.append(f'<rect x="282" y="90" width="84" height="44" rx="14" fill="{CARD}"/>'+T(324,118,0,'Grown-ups',14,700,NAVY,'middle'))
    # star bar
    b.append(chunky(16,152,358,104,28,CARD,LINE,4))
    b.append(star(70,204,32))
    b.append(T(120,206,0,'7',46,800)); b.append(T(150,206,0,'stars',18,700,INK2))
    b.append(T(350,206,0,'Park trip',16,700,INK2,'end'))
    for i in range(10):
        b.append(f'<rect x="{120+i*23.4}" y="224" width="19" height="14" rx="7" fill="{"#FFC83D" if i<7 else FILL}" stroke="{NAVY if i<7 else "none"}" stroke-width="1.5"/>')
    for i in range(10):
        cx=128+i*22.5; on=i<7
        b.append(f'<circle cx="{cx+100}" cy="214" r="0"/>')
    # progress: 10 chunky dots
    for i in range(10):
        x=120+i*24
        b.append(f'<rect x="{x}" y="226" width="0" height="0"/>')
    b.append(f'<rect x="120" y="258" width="0" height="0"/>')
    # simple bar progress
    b.append(f'<rect x="120" y="226" width="230" height="0"/>')
    # chores grid
    tiles=[('Make bed','bed','sky',True,None),('Brush teeth','tooth','berry',True,None),
           ('Feed Biscuit','paw','tan',False,'+2'),('Pack bag','bag','leaf',False,'+1'),
           ('Read 10 min','book','bubble',False,'+2'),('Toys away','toys','sun',False,'1 of 3')]
    x0,y0,tw,th,g=16,276,171,136,16
    for i,(name,kind,col,done,mark) in enumerate(tiles):
        x=x0+(i%2)*(tw+g); y=y0+(i//2)*(th+g+2)
        face,lip=KID['sky'] if done else KID[col]
        if done:
            b.append(chunky(x,y,tw,th,24,face,lip))
            b.append(f'<circle cx="{x+tw/2}" cy="{y+50}" r="28" fill="#FFFFFF"/>'+check(x+tw/2,y+51,36))
            b.append(T(x+tw/2,y+106,0,name,20,800,NAVY,'middle'))
            b.append(T(x+tw/2,y+127,0,'Done',15,700,NAVY,'middle'))
        else:
            b.append(chunky(x,y,tw,th,24,CARD,LINE))
            b.append(f'<circle cx="{x+tw/2}" cy="{y+50}" r="30" fill="{face}"/>'+picto(kind,x+tw/2,y+50,1.0))
            b.append(T(x+tw/2,y+106,0,name,20,800,NAVY,'middle'))
            if mark and mark.startswith('+'):
                b.append(star(x+tw/2-24,y+122,8,sw=1.6)+T(x+tw/2-12,y+128,0,mark+(' star' if mark=='+1' else ' stars'),15,700,INK2))
            else:
                b.append(T(x+tw/2,y+128,0,mark,15,700,INK2,'middle'))
    # read to me
    y=748
    b.append(chunky(16,y,358,72,24,NAVY,'#06121F',4))
    b.append(picto('speaker',72,y+36,0.95,'#FFFFFF'))
    b.append(T(104,y+44,0,'Read my jobs to me',20,800,'#FFFFFF'))
    return b
def fix_star_bar(b):
    return [s for s in b if 'width="0"' not in s and 'r="0"' not in s]
b=fix_star_bar(kid_phone())
# real progress bar under star count
prog=[f'<rect x="120" y="256" width="230" height="0"/>']
save('kid-chore-board-phone',390,844,''.join(b))

# ---------- 2. Wall display chore board 1920x1080 ----------
def wall():
    b=[]
    # top navigation bar: date left, text tabs centered with underline, clock right
    b.append(f'<rect x="0" y="0" width="1920" height="120" fill="{CARD}"/><rect x="0" y="120" width="1920" height="2" fill="{LINE}"/>')
    b.append(T(64,76,0,'Tuesday, October 29',40,800))
    for i,(lab,sel) in enumerate([('Week',False),('Chores',True),('Lists',False)]):
        x=820+i*150
        b.append(T(x,74,0,lab,30,800 if sel else 400,NAVY if sel else INK2,'middle'))
        if sel: b.append(f'<rect x="{x-50}" y="112" width="100" height="8" rx="4" fill="{NAVY}"/>')
    b.append(T(1856,80,0,'7:42',56,800,NAVY,'end'))
    kids=[('Leo','L','sky',7,[('Make bed','bed',1,'+1'),('Brush teeth','tooth',1,'+1'),('Feed Biscuit','paw',0,'+2'),('Pack bag','bag',0,'+1')]),
          ('Ava','A','leaf',12,[('Make bed','bed',1,'+1'),('Practice piano','music',1,'+2'),('Set the table','plate',1,'+1'),('Water plants','plant',0,'+1')]),
          ('Sam','S','tan',4,[('Brush teeth','tooth',1,'+1'),('Toys away','toys',0,'+1'),('Read 10 min','book',0,'+2'),('Shoes by door','bag',0,'+1')])]
    cw=576; gx=48
    for k,(name,ini,col,stars,jobs) in enumerate(kids):
        x=64+k*(cw+gx); face,lip=KID[col]
        b.append(avatar(x+48,206,44,face,ini))
        b.append(T(x+112,222,0,name,48,800))
        done=sum(j[2] for j in jobs)
        b.append(star(x+cw-112,204,26)+T(x+cw-76,220,0,str(stars),44,800))
        b.append(T(x+112,258,0,f'{done} of {len(jobs)} done',24,400,INK2))
        for j,(t,kind,d,pts) in enumerate(jobs):
            y=300+j*178
            if d:
                b.append(chunky(x,y,cw,156,32,face,lip,8))
                b.append(f'<circle cx="{x+86}" cy="{y+78}" r="48" fill="#FFFFFF"/>'+check(x+86,y+79,56))
                b.append(T(x+164,y+74,0,t,40,800)+T(x+164,y+114,0,'Done',26,700))
            else:
                b.append(chunky(x,y,cw,156,32,CARD,LINE,8))
                b.append(f'<circle cx="{x+86}" cy="{y+78}" r="50" fill="{face}"/>'+picto(kind,x+86,y+78,1.6))
                b.append(T(x+164,y+74,0,t,40,800))
                b.append(star(x+178,y+104,12,sw=2)+T(x+198,y+114,0,pts+(' star' if pts=='+1' else ' stars'),26,700,INK2))
                b.append(f'<circle cx="{x+cw-70}" cy="{y+78}" r="34" fill="none" stroke="#7F96AE" stroke-width="5"/>')
    return b
save('kid-chore-board-wall',1920,1080,''.join(wall()))

# ---------- 3. Family Soft calendar: light + dark phones ----------
SOFT=['#71C8FF','#7CE695','#C7A8FF','#FFB072']  # existing Soft pack: Bluebell, Mint, Lilac, Apricot
def cal(ox,dark):
    # Soft dark is true black (DenColors.softNightGround), with navy steps above it.
    bg,card,ink,ink2,fill,line,sel=(('#000000','#111F30','#EAF3FC','#A8BCD1','#192B40','#22364E','#1E4A73') if dark
        else (BG,CARD,NAVY,INK2,FILL,LINE,BABY))
    b=[f'<rect x="{ox}" y="0" width="390" height="844" fill="{bg}"/>']
    b.append(T(ox+24,58,0,'9:41',15,700,ink))
    b.append(T(ox+20,118,0,'October',32,800,ink))
    b.append(f'<circle cx="{ox+352}" cy="106" r="20" fill="{SOFT[0]}"/>'+T(ox+352,113,0,'M',18,800,NAVY,'middle'))
    # top segmented-free view switch: text tabs with underline
    for i,(lab,s) in enumerate([('Day',False),('Week',True),('Month',False)]):
        x=ox+20+i*80
        b.append(T(x,158,0,lab,17,700 if s else 400,ink if s else ink2))
        if s: b.append(f'<rect x="{x}" y="166" width="44" height="3" rx="1.5" fill="{ink}"/>')
    b.append(f'<rect x="{ox}" y="176" width="390" height="1" fill="{line}"/>')
    days=['S','M','T','W','T','F','S']; nums=[27,28,29,30,31,1,2]
    for i in range(7):
        x=ox+20+i*50
        if i==2: b.append(f'<rect x="{x}" y="190" width="44" height="64" rx="16" fill="{sel}"/>')
        b.append(T(x+22,214,0,days[i],13,400,ink2,'middle')+T(x+22,242,0,str(nums[i]),20,800 if i==2 else 400,ink,'middle'))
        dots=[[0],[1,2],[0,1,3],[2],[],[3,0],[1]][i]
        for d,ci in enumerate(dots): b.append(f'<circle cx="{x+22-(len(dots)-1)*5+d*10}" cy="262" r="3.5" fill="{SOFT[ci]}"/>')
    b.append(T(ox+20,302,0,'Today',20,800,ink))
    ev=[('7:30','Swim practice','Leo · Pool',0,'ball'),('9:00','Dentist','Ava · Dr. Kim',1,'tooth'),
        ('3:30','Piano lesson','Ava · Ms. Ruiz',1,'music'),('5:15','Pick up Sam','Mom · School',2,'car')]
    y=320
    for t,name,sub,ci,kind in ev:
        b.append(T(ox+20,y+30,0,t,15,700,ink2))
        b.append(f'<rect x="{ox+72}" y="{y}" width="298" height="76" rx="18" fill="{SOFT[ci]}"/>')
        b.append(picto(kind,ox+108,y+38,0.8,NAVY))
        b.append(T(ox+140,y+33,0,name,18,800,NAVY)+T(ox+140,y+56,0,sub,15,400,NAVY))
        y+=90
    # everyone block in ink
    b.append(T(ox+20,y+30,0,'6:30',15,700,ink2))
    b.append(f'<rect x="{ox+72}" y="{y}" width="298" height="76" rx="18" fill="{ink}"/>'+picto('plate',ox+108,y+38,0.8,bg))
    b.append(T(ox+140,y+33,0,'Family dinner',18,800,bg)+T(ox+140,y+56,0,'Everyone · Home',15,400,bg))
    return b
save('family-soft-calendar',820,844,''.join(cal(0,False)+cal(430,True)),bg='#FFFFFF')
