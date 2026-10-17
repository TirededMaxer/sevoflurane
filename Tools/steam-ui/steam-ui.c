#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static HANDLE output;
static BOOL first_dialog;
static WCHAR body[16384];
static UINT body_length;
static BOOL first_button;
static BOOL has_text;

static void bytes(const char *s) { DWORD n; UINT count=0; while(s[count]) count++; WriteFile(output,s,count,&n,0); }
static void number(ULONGLONG value) { char digits[24]; UINT n=0; do { digits[n++]=(char)('0'+value%10);value/=10; }while(value); while(n) { char text[2]={digits[--n],0};bytes(text); } }
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
 WCHAR text[256],kind[128];(void)ignored;
 GetClassNameW(child,kind,128);if(!equal(kind,L"Button")||!IsWindowEnabled(child)||!GetWindowTextW(child,text,256))return TRUE;
 if(!first_button)bytes(",");first_button=FALSE;
 bytes("{\"id\":");number((UINT)GetDlgCtrlID(child));bytes(",\"title\":");string(text);bytes("}");return TRUE;
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
 first_button=TRUE;EnumChildWindows(window,collect_button,0);bytes("]}");return TRUE;
}
static ULONGLONG parse(const WCHAR *s) { ULONGLONG value=0;while(*s>='0'&&*s<='9')value=value*10+(*s++-'0');return value; }
static LRESULT CALLBACK fixture_proc(HWND w,UINT msg,WPARAM wp,LPARAM lp) {
 if(msg==WM_COMMAND) {bytes("response:");number(LOWORD(wp));bytes("\n");DestroyWindow(w);return 0;}
 if(msg==WM_TIMER) {DestroyWindow(w);return 0;}
 if(msg==WM_DESTROY) {PostQuitMessage(0);return 0;}
 return DefWindowProcW(w,msg,wp,lp);
}
static void fixture(void) {
 WNDCLASSW cls={0};HWND w;MSG msg;cls.lpfnWndProc=fixture_proc;cls.hInstance=GetModuleHandleW(0);cls.lpszClassName=L"SevoErrorFixture";RegisterClassW(&cls);
 w=CreateWindowExW(0,cls.lpszClassName,L"Steam 测试错误",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_VISIBLE,100,100,420,180,0,0,cls.hInstance,0);
 CreateWindowExW(0,L"STATIC",L"连接失败：这是本地错误接管测试。",WS_CHILD|WS_VISIBLE,16,20,370,40,w,0,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"确定",WS_CHILD|WS_VISIBLE|BS_DEFPUSHBUTTON,220,82,80,28,w,(HMENU)IDOK,cls.hInstance,0);
 CreateWindowExW(0,L"BUTTON",L"取消",WS_CHILD|WS_VISIBLE,310,82,80,28,w,(HMENU)IDCANCEL,cls.hInstance,0);
 SetTimer(w,1,45000,0);
 while(GetMessageW(&msg,0,0,0)>0){TranslateMessage(&msg);DispatchMessageW(&msg);}
}
void mainCRTStartup(void) {
 typedef WCHAR **(WINAPI *split_fn)(const WCHAR *,int *);int count=0;WCHAR **args;
 split_fn split=(split_fn)GetProcAddress(LoadLibraryW(L"shell32.dll"),"CommandLineToArgvW");
 output=GetStdHandle(STD_OUTPUT_HANDLE);args=split(GetCommandLineW(),&count);
 if(count>1&&equal(args[1],L"--fixture")){fixture();ExitProcess(0);}
 if(count==5&&equal(args[1],L"answer")){
  HWND window=(HWND)(ULONG_PTR)parse(args[2]);DWORD expected=(DWORD)parse(args[3]),pid=0;UINT id=(UINT)parse(args[4]);
  GetWindowThreadProcessId(window,&pid);
  if(pid!=expected||!steam_process(pid))ExitProcess(3);
  if(id) {HWND button=GetDlgItem(window,id);if(!button||!IsWindowEnabled(button))ExitProcess(4);PostMessageW(window,WM_COMMAND,MAKEWPARAM(id,BN_CLICKED),(LPARAM)button);}
  else PostMessageW(window,WM_CLOSE,0,0);
  bytes("answered\n");ExitProcess(0);
 }
 first_dialog=TRUE;bytes("{\"dialogs\":[");EnumWindows(scan_window,0);bytes("]}\n");ExitProcess(0);
}
