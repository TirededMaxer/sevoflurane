#define WIN32_LEAN_AND_MEAN
#ifdef SEVO_STANDALONE
#include "win32-ui.h"
#else
#include <windows.h>
#endif

static HANDLE output;
static BOOL first_dialog;
static WCHAR body[16384];
static UINT body_length;
static BOOL first_button;
static BOOL has_text;
static UINT default_button;
static HWND scanned_window;

static void bytes(const char *s) { DWORD n; UINT count=0; while(s[count]) count++; WriteFile(output,s,count,&n,0); }
static void number(ULONGLONG value) { char digits[24]; UINT n=0; do { digits[n++]=(char)('0'+value%10);value/=10; }while(value); while(n) { char text[2]={digits[--n],0};bytes(text); } }
static void signed_number(int value) { if(value<0) { bytes("-");number((ULONGLONG)(-(long long)value)); } else number((UINT)value); }
static void string(const WCHAR *text) {
 static const char hex[]="0123456789abcdef"; bytes("\"");
 while(*text) { UINT c=*text++; char code[7]={'\\','u',hex[(c>>12)&15],hex[(c>>8)&15],hex[(c>>4)&15],hex[c&15],0};bytes(code); }
 bytes("\"");
}
static BOOL equal(const WCHAR *a,const WCHAR *b) {
 while(*a&&*b) { WCHAR x=*a++,y=*b++;if(x>='A'&&x<='Z')x+=32;if(y>='A'&&y<='Z')y+=32;if(x!=y)return FALSE; }return *a==*b;
}
static BOOL steam_process(DWORD pid) {
 static WCHAR path[2048]; WCHAR *name=path;DWORD count=2048;HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);BOOL ok=FALSE;
 if(!process)return FALSE;
 if(QueryFullProcessImageNameW(process,0,path,&count)) {
  WCHAR *at=path;while(*at) {if(*at=='\\'||*at=='/')name=at+1;at++;}
  ok=equal(name,L"steam.exe")||equal(name,L"steamerrorreporter.exe")||equal(name,L"steamerrorreporter64.exe");
 }
 CloseHandle(process);return ok;
}
static BOOL CALLBACK collect_text(HWND child,LPARAM ignored) {
 static WCHAR text[2048],kind[128];UINT i=0;(void)ignored;
 GetClassNameW(child,kind,128);
 if(equal(kind,L"Button"))return TRUE;
 if((GetWindowLongPtrW(child,GWL_STYLE)&ES_PASSWORD)&&equal(kind,L"Edit"))return TRUE;
 if(!GetWindowTextW(child,text,2048))return TRUE;
 if(body_length&&body_length<16382)body[body_length++]='\n';
 while(text[i]&&body_length<16382)body[body_length++]=text[i++];
 body[body_length]=0;has_text=TRUE;return TRUE;
}
static BOOL CALLBACK collect_button(HWND child,LPARAM ignored) {
 WCHAR text[256],kind[128];UINT type,id;(void)ignored;
 GetClassNameW(child,kind,128);type=(UINT)GetWindowLongPtrW(child,GWL_STYLE)&15;
 if(!equal(kind,L"Button")||!GetWindowTextW(child,text,256))return TRUE;
 if(type!=0&&type!=BS_DEFPUSHBUTTON&&type!=11&&type!=14&&type!=15)return TRUE;
 if(!first_button)bytes(",");first_button=FALSE;id=(UINT)GetDlgCtrlID(child);
 bytes("{\"id\":");number(id);bytes(",\"title\":");string(text);
 bytes(",\"enabled\":");bytes(IsWindowEnabled(child)?"true":"false");
 bytes(",\"default\":");bytes((default_button?id==default_button:type==BS_DEFPUSHBUTTON)?"true":"false");bytes("}");return TRUE;
}
static BOOL CALLBACK collect_toggle(HWND child,LPARAM ignored) {
 WCHAR text[256],kind[128];UINT type;(void)ignored;
 GetClassNameW(child,kind,128);type=(UINT)GetWindowLongPtrW(child,GWL_STYLE)&15;
 if(!equal(kind,L"Button")||!GetWindowTextW(child,text,256))return TRUE;
 if(type!=BS_CHECKBOX&&type!=BS_AUTOCHECKBOX&&type!=BS_RADIOBUTTON&&type!=BS_AUTORADIOBUTTON)return TRUE;
 if(!first_button)bytes(",");first_button=FALSE;
 bytes("{\"id\":");number((UINT)GetDlgCtrlID(child));bytes(",\"title\":");string(text);
 bytes(",\"radio\":");bytes((type==BS_RADIOBUTTON||type==BS_AUTORADIOBUTTON)?"true":"false");
 bytes(",\"enabled\":");bytes(IsWindowEnabled(child)?"true":"false");
 bytes(",\"checked\":");bytes(SendMessageW(child,BM_GETCHECK,0,0)==BST_CHECKED?"true":"false");bytes("}");return TRUE;
}
/* Copy an icon resource, not a screenshot of a window. The existing Steam
 * dialog chooses the actual icon; the host never guesses error severity. */
static void icon_data(HWND child) {
 HICON icon=(HICON)SendMessageW(child,STM_GETICON,0,0);HDC dc;HBITMAP bitmap;HGDIOBJ previous;BITMAPINFO info={0};void *pixels=0;UINT i;
 static const char hex[]="0123456789abcdef";static char encoded[8193];
 if(!icon)return;dc=CreateCompatibleDC(0);if(!dc)return;
 info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=32;info.bmiHeader.biHeight=-32;
 info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
 bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&pixels,0,0);
 if(!bitmap){DeleteDC(dc);return;}
 for(i=0;i<4096;i++)((unsigned char *)pixels)[i]=0;
 previous=SelectObject(dc,bitmap);DrawIconEx(dc,0,0,icon,32,32,0,0,DI_NORMAL);GdiFlush();
 /* Legacy icons may lack an alpha channel; keep their drawn pixels. */
 {BOOL alpha=FALSE;for(i=3;i<4096;i+=4)if(((unsigned char *)pixels)[i])alpha=TRUE;
  if(!alpha)for(i=0;i<4096;i+=4)if(((unsigned char *)pixels)[i]||((unsigned char *)pixels)[i+1]||((unsigned char *)pixels)[i+2])((unsigned char *)pixels)[i+3]=255;}
 bytes(",\"iconBGRA\":\"");
 for(i=0;i<4096;i++){UINT c=((unsigned char *)pixels)[i];encoded[i*2]=hex[c>>4];encoded[i*2+1]=hex[c&15];}
 encoded[8192]=0;bytes(encoded);
 bytes("\"");SelectObject(dc,previous);DeleteObject(bitmap);DeleteDC(dc);
}
/* The original client rectangle and individual control geometry are the UI
 * contract. Do not collapse a dialog into a message-box summary. */
static BOOL CALLBACK collect_control(HWND child,LPARAM ignored) {
 static WCHAR text[2048],kind[128];RECT rect;POINT origin;UINT style,type,id;BOOL password;(void)ignored;
 if(!IsWindowVisible(child))return TRUE;
 GetClassNameW(child,kind,128);style=(UINT)GetWindowLongPtrW(child,GWL_STYLE);type=style&15;
 password=equal(kind,L"Edit")&&(style&ES_PASSWORD);
 text[0]=0;if(!password)GetWindowTextW(child,text,2048);
 if(!GetWindowRect(child,&rect))return TRUE;
 origin.x=rect.left;origin.y=rect.top;ScreenToClient(scanned_window,&origin);
 if(!first_button)bytes(",");first_button=FALSE;id=(UINT)GetDlgCtrlID(child);
 bytes("{\"handle\":");number((ULONG_PTR)child);bytes(",\"id\":");number(id);
 bytes(",\"className\":");string(kind);bytes(",\"text\":");string(text);
 bytes(",\"style\":");number(style);bytes(",\"x\":");signed_number(origin.x);bytes(",\"y\":");signed_number(origin.y);
 bytes(",\"width\":");signed_number(rect.right-rect.left);bytes(",\"height\":");signed_number(rect.bottom-rect.top);
 bytes(",\"enabled\":");bytes(IsWindowEnabled(child)?"true":"false");
 bytes(",\"tabStop\":");bytes((style&WS_TABSTOP)?"true":"false");
 bytes(",\"password\":");bytes(password?"true":"false");
 bytes(",\"default\":");bytes(equal(kind,L"Button")&&(default_button?id==default_button:type==BS_DEFPUSHBUTTON)?"true":"false");
 bytes(",\"checkState\":");number(equal(kind,L"Button")?(UINT)SendMessageW(child,BM_GETCHECK,0,0):0);
 if(equal(kind,L"msctls_progress32")) {
  bytes(",\"value\":");number((UINT)SendMessageW(child,PBM_GETPOS,0,0));
  bytes(",\"minimum\":");number((UINT)SendMessageW(child,PBM_GETRANGE,TRUE,0));
  bytes(",\"maximum\":");number((UINT)SendMessageW(child,PBM_GETRANGE,FALSE,0));
 }
 if(equal(kind,L"Static")&&(style&31)==3)icon_data(child);
 bytes("}");return TRUE;
}
static BOOL CALLBACK scan_window(HWND window,LPARAM ignored) {
 DWORD pid;static WCHAR title[2048],kind[128];BOOL standard;(void)ignored;
 GetWindowThreadProcessId(window,&pid);if(!steam_process(pid)||!IsWindowVisible(window)||!GetWindowTextW(window,title,2048))return TRUE;
 GetClassNameW(window,kind,128);
 standard=equal(kind,L"#32770")||equal(kind,L"SevoErrorFixture");
 if(!standard && !equal(kind,L"vguiPopupWindow") && !equal(kind,L"SDL_app"))return TRUE;
 body_length=0;body[0]=0;has_text=FALSE;EnumChildWindows(window,collect_text,0);
 if(!standard&&!has_text)return TRUE;
 if(!first_dialog)bytes(",");first_dialog=FALSE;
 bytes("{\"handle\":");number((ULONG_PTR)window);bytes(",\"pid\":");number(pid);bytes(",\"title\":");string(title);bytes(",\"body\":");string(body);bytes(",\"buttons\":[");
 {LRESULT choice=SendMessageW(window,DM_GETDEFID,0,0);default_button=HIWORD(choice)==DC_HASDEFID?LOWORD(choice):0;}
 first_button=TRUE;EnumChildWindows(window,collect_button,0);
 bytes("],\"toggles\":[");first_button=TRUE;EnumChildWindows(window,collect_toggle,0);
 bytes("],\"controls\":[");first_button=TRUE;scanned_window=window;EnumChildWindows(window,collect_control,0);
 {RECT rect={0};GetClientRect(window,&rect);bytes("],\"clientWidth\":");signed_number(rect.right);bytes(",\"clientHeight\":");signed_number(rect.bottom);}
 bytes(",\"canClose\":");bytes((GetWindowLongPtrW(window,GWL_STYLE)&WS_SYSMENU)?"true":"false");
 bytes("}");return TRUE;
}
static ULONGLONG parse(const WCHAR *s) { ULONGLONG value=0;while(*s>='0'&&*s<='9')value=value*10+(*s++-'0');return value; }
static LRESULT CALLBACK fixture_proc(HWND w,UINT msg,WPARAM wp,LPARAM lp) {
 if(msg==DM_GETDEFID)return MAKEWPARAM(IDCANCEL,DC_HASDEFID);
 if(msg==WM_COMMAND&&LOWORD(wp)==21) {bytes("toggle:");number(SendMessageW((HWND)lp,BM_GETCHECK,0,0));bytes("\n");return 0;}
 if(msg==WM_COMMAND) {bytes("response:");number(LOWORD(wp));bytes("\n");DestroyWindow(w);return 0;}
 if(msg==WM_TIMER) {DestroyWindow(w);return 0;}
 if(msg==WM_DESTROY) {PostQuitMessage(0);return 0;}
 return DefWindowProcW(w,msg,wp,lp);
}
static void fixture(void) {
 WNDCLASSW cls={0};HWND w;MSG msg;cls.lpfnWndProc=fixture_proc;cls.hInstance=GetModuleHandleW(0);cls.lpszClassName=L"SevoErrorFixture";RegisterClassW(&cls);
 w=CreateWindowExW(0,cls.lpszClassName,L"Steam 测试错误",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_VISIBLE,100,100,420,180,0,0,cls.hInstance,0);
 CreateWindowExW(0,L"STATIC",L"连接失败：这是本地错误接管测试。",WS_CHILD|WS_VISIBLE,16,20,370,40,w,0,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"确定",WS_CHILD|WS_VISIBLE|WS_TABSTOP,220,82,80,28,w,(HMENU)IDOK,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"取消",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,310,82,80,28,w,(HMENU)IDCANCEL,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"保留原始选项",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTOCHECKBOX,16,65,180,24,w,(HMENU)21,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"重试",WS_CHILD|WS_VISIBLE|WS_DISABLED,16,96,80,24,w,(HMENU)4,cls.hInstance,0);
 SetTimer(w,1,45000,0);
 while(GetMessageW(&msg,0,0,0)>0){TranslateMessage(&msg);DispatchMessageW(&msg);}
}
void mainCRTStartup(void) {
 typedef WCHAR **(WINAPI *split_fn)(const WCHAR *,int *);int count=0;WCHAR **args;
 split_fn split=(split_fn)GetProcAddress(LoadLibraryW(L"shell32.dll"),"CommandLineToArgvW");
 output=GetStdHandle(STD_OUTPUT_HANDLE);args=split(GetCommandLineW(),&count);
 if(count>1&&equal(args[1],L"--fixture")){fixture();ExitProcess(0);}
 if((count==6||count==7)&&equal(args[1],L"control")) {
  HWND window=(HWND)(ULONG_PTR)parse(args[2]),child=(HWND)(ULONG_PTR)parse(args[4]);
  DWORD expected=(DWORD)parse(args[3]),pid=0,child_pid=0;
  GetWindowThreadProcessId(window,&pid);GetWindowThreadProcessId(child,&child_pid);
  if(pid!=expected||child_pid!=pid||!steam_process(pid)||!IsChild(window,child))ExitProcess(3);
  if(!IsWindowVisible(child)||!IsWindowEnabled(child))ExitProcess(4);
  if(equal(args[5],L"click"))PostMessageW(child,BM_CLICK,0,0);
  else if(equal(args[5],L"focus"))PostMessageW(window,WM_NEXTDLGCTL,(WPARAM)child,TRUE);
  else if(count==7&&equal(args[5],L"text-file")) {
   WCHAR kind[128];HANDLE file;long long size=0;DWORD read=0;WCHAR *text;
   GetClassNameW(child,kind,128);if(!equal(kind,L"Edit"))ExitProcess(5);
   file=CreateFileW(args[6],GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
   if(file==INVALID_HANDLE_VALUE)ExitProcess(6);
   if(!GetFileSizeEx(file,&size)||size<0||size>0x7ffffffe||(size&1)){CloseHandle(file);ExitProcess(6);}
   text=HeapAlloc(GetProcessHeap(),0,(ULONG_PTR)size+2);if(!text){CloseHandle(file);ExitProcess(6);}
   if(!ReadFile(file,text,(DWORD)size,&read,0)||read!=(DWORD)size){CloseHandle(file);HeapFree(GetProcessHeap(),0,text);ExitProcess(6);}
   text[size/2]=0;CloseHandle(file);SetWindowTextW(child,text);HeapFree(GetProcessHeap(),0,text);
  }
  else ExitProcess(5);
  bytes("forwarded\n");ExitProcess(0);
 }
 if(count==5&&equal(args[1],L"answer")){
  HWND window=(HWND)(ULONG_PTR)parse(args[2]);DWORD expected=(DWORD)parse(args[3]),pid=0;UINT id=(UINT)parse(args[4]);
  GetWindowThreadProcessId(window,&pid);
  if(pid!=expected||!steam_process(pid))ExitProcess(3);
  if(id) {HWND button=GetDlgItem(window,id);if(!button||!IsWindowEnabled(button))ExitProcess(4);PostMessageW(button,BM_CLICK,0,0);}
  else PostMessageW(window,WM_CLOSE,0,0);
  bytes("answered\n");ExitProcess(0);
 }
 first_dialog=TRUE;bytes("{\"dialogs\":[");EnumWindows(scan_window,0);bytes("]}\n");ExitProcess(0);
}
