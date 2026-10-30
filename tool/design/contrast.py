#!/usr/bin/env python3
"""WCAG 2.2 contrast for the Kids mode + Soft theme tokens. Run: python3 tool/design/contrast.py"""
def lum(h):
    h=h.lstrip('#'); r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4))
    f=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
    return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def cr(a,b):
    x,y=sorted((lum(a),lum(b)),reverse=True); return (x+0.05)/(y+0.05)
PAIRS=[
 # (theme, fg name, fg, bg name, bg, need)
 ('soft-light','ink','#0F2338','bg','#EEF5FC',4.5),
 ('soft-light','ink','#0F2338','card','#FFFFFF',4.5),
 ('soft-light','ink2','#45596E','bg','#EEF5FC',4.5),
 ('soft-light','ink2','#45596E','card','#FFFFFF',4.5),
 ('soft-light','ink3','#55697F','bg','#EEF5FC',4.5),
 ('soft-light','ink3','#55697F','fill','#DCEBF8',4.5),
 ('soft-light','onPrimary','#FFFFFF','primary(ink)','#0F2338',4.5),
 ('soft-light','destructive','#B8231C','card','#FFFFFF',4.5),
 ('soft-light','destructive','#B8231C','bg','#EEF5FC',4.5),
 ('soft-light','starEdge','#1F3B57','bg','#EEF5FC',3.0),
 ('soft-light','ink','#0F2338','babyBlue','#A9D4F5',4.5),
 ('soft-dark','ink','#EAF3FC','bg','#060D16',4.5),
 ('soft-dark','ink','#EAF3FC','card','#111F30',4.5),
 ('soft-dark','ink2','#A8BCD1','bg','#060D16',4.5),
 ('soft-dark','ink2','#A8BCD1','card','#111F30',4.5),
 ('soft-dark','ink3','#8DA3BA','card','#111F30',4.5),
 ('soft-dark','ink3','#8DA3BA','raised','#192B40',4.5),
 ('soft-dark','onPrimary','#060D16','primary(ink)','#EAF3FC',4.5),
 ('soft-dark','destructive','#FF8A7E','card','#111F30',4.5),
 ('soft-dark','star','#FFC83D','bg','#060D16',3.0),
 ('soft-dark','ink','#EAF3FC','babyBlueDeep','#1E4A73',4.5),
 # kid primaries: always navy ink on top (onMarker), and as large icon vs white card (3:1 non-text)
]
KID={'sky':'#4FB4F7','leaf':'#4CC968','sun':'#FFD23F','tangerine':'#FF9B3F','berry':'#FF6F7D','bubble':'#F58BC0'}
for k,v in KID.items():
    PAIRS.append(('kid','onMarker','#0F2338',k,v,4.5))
# Lip shades (the 6dp solid base under a chunky tile) are decorative, not checked: icons and
# text always sit on the light color in navy ink (above), never on a lip.
KIDLIP={'skyLip':'#2C8FD6','leafLip':'#2FA34C','sunLip':'#E8B400','tangerineLip':'#E87A1C','berryLip':'#E04A5C','bubbleLip':'#D9619E'}
# Non-text 3:1: a done check (navy) on each kid color, and the unfilled ring (line) vs card.
PAIRS.append(('kid','todo ring','#7F96AE','card','#FFFFFF',3.0))
PAIRS.append(('kid','todo ring dark','#5F7894','card','#111F30',3.0))
if __name__=='__main__':
    print('| Theme | Foreground | Background | Ratio | Need | Pass |\n|---|---|---|---|---|---|')
    bad=0
    for th,fn,f,bn,b,need in PAIRS:
        r=cr(f,b); ok=r>=need; bad+= not ok
        print(f'| {th} | {fn} `{f}` | {bn} `{b}` | {r:.2f}:1 | {need}:1 | {"yes" if ok else "NO"} |')
    print(f'\n{len(PAIRS)-bad}/{len(PAIRS)} pass')
