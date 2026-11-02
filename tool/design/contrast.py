#!/usr/bin/env python3
"""WCAG 2.2 contrast for the Kids mode + Soft theme tokens. Run: python3 tool/design/contrast.py

The hexes mirror app/lib/design/tokens.dart and kid_tokens.dart; app/test/design/tokens_test.dart
checks the same pairs against the Dart tokens themselves."""
def lum(h):
    h=h.lstrip('#'); r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4))
    f=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
    return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def cr(a,b):
    x,y=sorted((lum(a),lum(b)),reverse=True); return (x+0.05)/(y+0.05)
# Soft's ground at night (DenColors.softNightGround): true black, the owner's choice
# (2026-10-30) over navy-black #060D16. One token: bg, the bar and text on an ink fill.
SOFT_NIGHT_GROUND='#000000'
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
 ('soft-dark','ink','#EAF3FC','bg',SOFT_NIGHT_GROUND,4.5),
 ('soft-dark','ink','#EAF3FC','card','#111F30',4.5),
 ('soft-dark','ink2','#A8BCD1','bg',SOFT_NIGHT_GROUND,4.5),
 ('soft-dark','ink2','#A8BCD1','card','#111F30',4.5),
 ('soft-dark','ink3','#8DA3BA','card','#111F30',4.5),
 ('soft-dark','ink3','#8DA3BA','raised','#192B40',4.5),
 ('soft-dark','onPrimary',SOFT_NIGHT_GROUND,'primary(ink)','#EAF3FC',4.5),
 ('soft-dark','destructive','#FF8A7E','card','#111F30',4.5),
 ('soft-dark','star','#FFC83D','bg',SOFT_NIGHT_GROUND,3.0),
 ('soft-dark','ink','#EAF3FC','babyBlueDeep','#1E4A73',4.5),
 # With a true black page: quiet text and red on the page itself, and red on a menu.
 ('soft-dark','ink3','#8DA3BA','bg',SOFT_NIGHT_GROUND,4.5),
 ('soft-dark','destructive','#FF8A7E','bg',SOFT_NIGHT_GROUND,4.5),
 ('soft-dark','destructive','#FF8A7E','raised','#192B40',4.5),
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
# Kids mode in Day and Night too: a neutral ring on their cards.
PAIRS.append(('kid','todo ring day','#8C8C8C','card','#FFFFFF',3.0))
PAIRS.append(('kid','todo ring night','#6B6B6B','card','#141414',3.0))
# Soft's onMarker on every color of every family pack. A Soft family can still pick Deep or
# Bold, where Soft's ink #0F2338 falls to 4.16:1, so person colors get a deeper navy that keeps
# the packs' own bar (4.8:1, DESIGN.md "Family colors").
SOFT_ON_MARKER='#071426'
PACKS={
 'bright':['#339FEE','#4CC157','#AD87ED','#F88B1C','#10CACA','#F05653','#F4CE23','#F075AA'],
 'deep':['#2682FF','#009D4F','#9D64F6','#E97200','#009EA4','#F33A3F','#ECC906','#EC3F94'],
 'soft':['#71C8FF','#7CE695','#C7A8FF','#FFB072','#5DE9E9','#FF8482','#FEE657','#FA96C3'],
 'bold':['#477FFF','#30C532','#B853FF','#FF7902','#06C1EC','#FF2920','#F5DA04','#F33BBF']}
PACK_PAIRS=[(p,c,SOFT_ON_MARKER,4.8) for p,cols in PACKS.items() for c in cols]
if __name__=='__main__':
    print('| Theme | Foreground | Background | Ratio | Need | Pass |\n|---|---|---|---|---|---|')
    bad=0
    for th,fn,f,bn,b,need in PAIRS:
        r=cr(f,b); ok=r>=need; bad+= not ok
        print(f'| {th} | {fn} `{f}` | {bn} `{b}` | {r:.2f}:1 | {need}:1 | {"yes" if ok else "NO"} |')
    print(f'\n{len(PAIRS)-bad}/{len(PAIRS)} pass')
    print(f'\nSoft onMarker `{SOFT_ON_MARKER}` on every family color (need 4.8:1):\n')
    print('| Pack | Lowest | On | Pass |\n|---|---|---|---|')
    pbad=0
    for p,cols in PACKS.items():
        low,on=min((cr(SOFT_ON_MARKER,c),c) for c in cols)
        fails=sum(cr(SOFT_ON_MARKER,c)<4.8 for c in cols); pbad+=fails
        print(f'| {p} | {low:.2f}:1 | `{on}` | {"yes" if not fails else "NO"} |')
    print(f'\n{len(PACK_PAIRS)-pbad}/{len(PACK_PAIRS)} pack colors pass')
    print(f'\n{len(PAIRS)+len(PACK_PAIRS)-bad-pbad}/{len(PAIRS)+len(PACK_PAIRS)} pass in all')
    raise SystemExit(1 if bad or pbad else 0)
