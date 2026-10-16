from pathlib import Path
import subprocess, argparse
parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
options=parser.parse_args()
source=options.source.resolve()
output=options.output.resolve();output.mkdir(parents=True,exist_ok=True)
window=(source/'cocoa_window.m').read_text().split('@implementation WineWindow\n',1)[1].split('    static WineWindow* causing_becomeKeyWindow;',1)[0]
tray=(source/'cocoa_status_item.m').read_text().split('    - (id) initWithEventQueue:',1)[1].split('    - (void) dealloc',1)[0]
code=r'''#import <Cocoa/Cocoa.h>
#include <assert.h>
#include "sevo_ui_policy.h"
bool sevo_ui_suppressed(void) { return sevo_ui_policy(); }
void sevo_ui_record(NSString *kind, NSWindow *window) { (void)kind; (void)window; }
@interface WineWindow : NSWindow @end
@implementation WineWindow
WINDOW_METHODS
@end
@class WineEventQueue;
@interface WineStatusItem : NSView {
 NSStatusItem *item;
 id queue;
 NSTrackingArea *trackingArea;
}
@property(retain) NSStatusItem *item;
@end
@implementation WineStatusItem
@synthesize item;
- (id)initWithEventQueue:TRAY_METHOD
@end
int main(int argc, char **argv) {
 @autoreleasepool {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  char *real=argv[0];
  setenv("SEVO_OWNER_PID","123",1);setenv("CX_HIDE_STEAM_DOCK","1",1);
  NSArray *programs=@[@"steam.exe",@"steamwebhelper.exe",@"steamerrorreporter64.exe",@"explorer.exe",@"cs2.exe"];
  unsigned checks=0;
  for (NSString *program in programs) {
   argv[0]=(char *)[program UTF8String];
   BOOL hidden=![program isEqualToString:@"cs2.exe"];
   WineWindow *window=[[WineWindow alloc] initWithContentRect:NSMakeRect(100,100,240,120) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
   [window setTitle:@"Sevoflurane UI regression test"];
   [window setReleasedWhenClosed:NO];
   [window orderFront:nil];assert([window isVisible] != hidden);checks++;
   [window orderOut:nil];assert(![window isVisible]);checks++;
   [window orderWindow:NSWindowAbove relativeTo:0];assert([window isVisible] != hidden);checks++;
   [window orderWindow:NSWindowOut relativeTo:0];assert(![window isVisible]);checks++;
   [window orderFrontRegardless];assert([window isVisible] != hidden);checks++;
   [window close];[window release];
   WineStatusItem *status=[[WineStatusItem alloc] initWithEventQueue:nil];
   assert(([status item]==nil)==hidden);checks++;
   if ([status item]) {[[NSStatusBar systemStatusBar] removeStatusItem:[status item]];[[status item] setView:nil];[status setItem:nil];}
   [status release];
  }
  argv[0]="steam.exe";unsetenv("SEVO_OWNER_PID");
  WineWindow *ordinary=[[WineWindow alloc] initWithContentRect:NSMakeRect(100,100,240,120) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  [ordinary setReleasedWhenClosed:NO];[ordinary orderFront:nil];assert([ordinary isVisible]);checks++;
  [ordinary close];[ordinary release];argv[0]=real;
  printf("PASS: %u AppKit visibility, order-out, tray and normal-CrossOver checks\n",checks);
 }
 return 0;
}
'''.replace('WINDOW_METHODS',window).replace('TRAY_METHOD',tray)
(output/'appkit.m').write_text(code)
subprocess.run(['clang','-I'+str(source),str(output/'appkit.m'),'-framework','Cocoa','-o',str(output/'appkit')],check=True)
subprocess.run([str(output/'appkit')],check=True)
