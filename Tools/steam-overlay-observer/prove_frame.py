"""One command: identify the original overlay, size one Mac frame, attach the existing proof."""
import argparse
import json
from pathlib import Path
import re
import struct
import tempfile
import cdp
import observer


def prepare_packet(data, info):
    if len(data)<24:
        raise RuntimeError('Truncated Mac frame')
    magic,sw,sh,_,size=struct.unpack('<8sIIII',data[:24])
    tw,th=(round(info[k]*info['scale']) for k in ('width','height'))
    target=info['browserID']
    if (magic!=b'SEVOFRM1' or not 64<=sw<=8192 or not 64<=sh<=8192 or size!=sw*sh*4
            or len(data)!=24+size or not 64<=tw<=8192 or not 64<=th<=8192 or not 0<target<2**31
            or tw*th*4>128*1024*1024):
        raise RuntimeError('Invalid Mac/native frame dimensions or CEF identifier')
    pixels=memoryview(data)[24:]
    if (sw,sh)==(tw,th):
        resized=pixels.tobytes()
    else:
        xs=[x*sw//tw*4 for x in range(tw)]
        rows=[]
        for y in range(th):
            row=pixels[(y*sh//th)*sw*4:((y*sh//th)+1)*sw*4]
            rows.append(b''.join(row[x:x+4] for x in xs))
        resized=b''.join(rows)
    return struct.pack('<8sIIII',magic,tw,th,target,len(resized))+resized


def one_overlay(targets):
    matches=[t for t in targets if t.get('type')=='page' and
             re.fullmatch(r'SP Overlay: [0-9]+/[0-9]+/[0-9]+',t.get('title',''))]
    if len(matches)!=1:
        raise RuntimeError('Expected one original Steam overlay; found '+str(len(matches)))
    return matches[0]['title']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mac_frame',type=Path)
    args=parser.parse_args()
    title=one_overlay(cdp.targets())
    expression='({title:document.title,browserID:SteamClient.Browser.GetBrowserID(),width:innerWidth,height:innerHeight,scale:devicePixelRatio})'
    reply=cdp.send(title,'Runtime.evaluate',{'expression':expression,'returnByValue':True})
    info=reply['result']['result']['value']
    if info['title']!=title:
        raise RuntimeError('Original overlay changed during identification')
    packet=prepare_packet(args.mac_frame.read_bytes(),info)
    with tempfile.TemporaryDirectory(prefix='sevo-frame-packet-',dir='/private/tmp') as temporary:
        frame=Path(temporary)/'frame.bgra';frame.write_bytes(packet)
        print(json.dumps({'target':title,'cef_id':info['browserID'],'stage':'attaching-one-Mac-frame'}),flush=True)
        steam=Path.home()/'Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam'
        return observer.attach(Path(__file__).resolve().parent,steam,None,'cpp',frame)


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except (OSError,ValueError,KeyError,RuntimeError) as error:
        raise SystemExit(str(error)) from None
