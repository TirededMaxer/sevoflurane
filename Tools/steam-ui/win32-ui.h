/* Minimal Win32 ABI declarations used by the dialog presentation bridge.
 * No Windows SDK or Wine build/cache is required on the cloud runner. */
#ifndef SEVO_WIN32_UI_H
#define SEVO_WIN32_UI_H
#define WINAPI
#define CALLBACK
#define TRUE 1
#define FALSE 0
#define NULL ((void *)0)
typedef int BOOL;
typedef unsigned int UINT, DWORD;
typedef unsigned short WCHAR, ATOM;
typedef unsigned long long ULONGLONG, ULONG_PTR, WPARAM;
typedef long long LONG_PTR, LPARAM, LRESULT;
typedef void *HANDLE, *HWND, *HINSTANCE, *HICON, *HCURSOR, *HBRUSH, *HMENU, *HDC, *HBITMAP, *HGDIOBJ;
typedef LRESULT (CALLBACK *WNDPROC)(HWND,UINT,WPARAM,LPARAM);
typedef BOOL (CALLBACK *WNDENUMPROC)(HWND,LPARAM);
typedef HANDLE HFONT;
typedef struct { int lfHeight,lfWidth,lfEscapement,lfOrientation,lfWeight; unsigned char lfItalic,lfUnderline,lfStrikeOut,lfCharSet,lfOutPrecision,lfClipPrecision,lfQuality,lfPitchAndFamily; WCHAR lfFaceName[32]; } LOGFONTW;
typedef struct { int tmHeight,tmAscent,tmDescent,tmInternalLeading,tmExternalLeading,tmAveCharWidth,tmMaxCharWidth,tmWeight,tmOverhang,tmDigitizedAspectX,tmDigitizedAspectY; WCHAR tmFirstChar,tmLastChar,tmDefaultChar,tmBreakChar; unsigned char tmItalic,tmUnderlined,tmStruckOut,tmPitchAndFamily,tmCharSet; } TEXTMETRICW;
typedef struct { UINT lbStyle; DWORD lbColor; ULONG_PTR lbHatch; } LOGBRUSH;
#define GW_OWNER 4
#define WM_GETTEXT 13
#define WM_SETTEXT 12
#define WM_GETFONT 0x31
#define DEFAULT_GUI_FONT 17
#define WM_CTLCOLOREDIT 0x133
#define WM_CTLCOLORBTN 0x135
#define WM_CTLCOLORSTATIC 0x138
#define SMTO_ABORTIFHUNG 2
#define BS_SOLID 0
#define COLOR_WINDOW 5
#define COLOR_WINDOWTEXT 8
#define COLOR_BTNFACE 15
#define COLOR_BTNTEXT 18
#define COLOR_HIGHLIGHT 13
#define COLOR_HIGHLIGHTTEXT 14
#define COLOR_BTNSHADOW 16
#define COLOR_BTNHIGHLIGHT 20
#define COLOR_GRAYTEXT 17
#define COLOR_ACTIVECAPTION 2
#define COLOR_CAPTIONTEXT 9
typedef struct { int x,y; } POINT;
typedef struct { int left,top,right,bottom; } RECT;
typedef struct { DWORD biSize; int biWidth,biHeight; unsigned short biPlanes,biBitCount; DWORD biCompression,biSizeImage; int biXPelsPerMeter,biYPelsPerMeter; DWORD biClrUsed,biClrImportant; } BITMAPINFOHEADER;
typedef struct { unsigned char rgbBlue,rgbGreen,rgbRed,rgbReserved; } RGBQUAD;
typedef struct { BITMAPINFOHEADER bmiHeader; RGBQUAD bmiColors[1]; } BITMAPINFO;
typedef struct { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; DWORD lPrivate; } MSG;
typedef struct { UINT style; WNDPROC lpfnWndProc; int cbClsExtra,cbWndExtra; HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; const WCHAR *lpszMenuName,*lpszClassName; } WNDCLASSW;
#define GENERIC_READ 0x80000000u
#define FILE_SHARE_READ 1
#define OPEN_EXISTING 3
#define FILE_ATTRIBUTE_NORMAL 0x80
#define INVALID_HANDLE_VALUE ((HANDLE)(LONG_PTR)-1)
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define GWL_STYLE (-16)
#define ES_PASSWORD 0x20
#define WS_TABSTOP 0x00010000u
#define WM_NEXTDLGCTL 0x28
#define STM_GETICON 0x171
#define DI_NORMAL 3
#define DIB_RGB_COLORS 0
#define BI_RGB 0
#define PBM_GETPOS 0x408
#define PBM_GETRANGE 0x407
#define BS_DEFPUSHBUTTON 1
#define BS_CHECKBOX 2
#define BS_AUTOCHECKBOX 3
#define BS_RADIOBUTTON 4
#define BS_AUTORADIOBUTTON 9
#define WS_OVERLAPPED 0
#define WS_CAPTION 0x00c00000u
#define WS_SYSMENU 0x00080000u
#define WS_VISIBLE 0x10000000u
#define WS_CHILD 0x40000000u
#define WS_DISABLED 0x08000000u
#define IDOK 1
#define IDCANCEL 2
#define BN_CLICKED 0
#define WM_DESTROY 2
#define WM_CLOSE 16
#define WM_COMMAND 0x111
#define WM_TIMER 0x113
#define BM_GETCHECK 0xf0
#define BM_CLICK 0xf5
#define DM_GETDEFID 0x400
#define DC_HASDEFID 0x534b
#define BST_CHECKED 1
#define LOWORD(v) ((unsigned short)((ULONG_PTR)(v)&0xffff))
#define HIWORD(v) ((unsigned short)(((ULONG_PTR)(v)>>16)&0xffff))
#define MAKEWPARAM(a,b) ((WPARAM)(((unsigned short)(a))|((DWORD)((unsigned short)(b))<<16)))
#define API __declspec(dllimport)
API HANDLE WINAPI OpenProcess(DWORD,BOOL,DWORD);
API BOOL WINAPI QueryFullProcessImageNameW(HANDLE,DWORD,WCHAR *,DWORD *);
API BOOL WINAPI CloseHandle(HANDLE);
API HANDLE WINAPI CreateFileW(const WCHAR *,DWORD,DWORD,void *,DWORD,DWORD,HANDLE);
API BOOL WINAPI ReadFile(HANDLE,void *,DWORD,DWORD *,void *);
API BOOL WINAPI GetFileSizeEx(HANDLE,long long *);
API HANDLE WINAPI GetProcessHeap(void);
API void *WINAPI HeapAlloc(HANDLE,DWORD,ULONG_PTR);
API BOOL WINAPI HeapFree(HANDLE,DWORD,void *);
API BOOL WINAPI WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
API HANDLE WINAPI GetStdHandle(DWORD);
API WCHAR *WINAPI GetCommandLineW(void);
API __declspec(noreturn) void WINAPI ExitProcess(UINT);
API HINSTANCE WINAPI GetModuleHandleW(const WCHAR *);
API HINSTANCE WINAPI LoadLibraryW(const WCHAR *);
API void *WINAPI GetProcAddress(HINSTANCE,const char *);
API DWORD WINAPI GetWindowThreadProcessId(HWND,DWORD *);
API BOOL WINAPI IsWindowVisible(HWND);
API int WINAPI GetClassNameW(HWND,WCHAR *,int);
API LONG_PTR WINAPI GetWindowLongPtrW(HWND,int);
API BOOL WINAPI EnumChildWindows(HWND,WNDENUMPROC,LPARAM);
API BOOL WINAPI EnumWindows(WNDENUMPROC,LPARAM);
API BOOL WINAPI IsWindowEnabled(HWND);
API int WINAPI GetDlgCtrlID(HWND);
API BOOL WINAPI GetClientRect(HWND,RECT *);
API BOOL WINAPI GetWindowRect(HWND,RECT *);
API BOOL WINAPI ScreenToClient(HWND,POINT *);
API BOOL WINAPI IsChild(HWND,HWND);
API BOOL WINAPI DrawIconEx(HDC,int,int,HICON,int,int,UINT,HBRUSH,UINT);
API HDC WINAPI CreateCompatibleDC(HDC);
API BOOL WINAPI DeleteDC(HDC);
API BOOL WINAPI GdiFlush(void);
API HGDIOBJ WINAPI SelectObject(HDC,HGDIOBJ);
API BOOL WINAPI DeleteObject(HGDIOBJ);
API HBITMAP WINAPI CreateDIBSection(HDC,const BITMAPINFO *,UINT,void **,HANDLE,DWORD);
API HWND WINAPI GetDlgItem(HWND,int);
API BOOL WINAPI PostMessageW(HWND,UINT,WPARAM,LPARAM);
API LRESULT WINAPI SendMessageTimeoutW(HWND,UINT,WPARAM,LPARAM,UINT,UINT,ULONG_PTR *);
API HDC WINAPI GetDC(HWND);
API int WINAPI ReleaseDC(HWND,HDC);
API HWND WINAPI GetParent(HWND);
API HWND WINAPI GetWindow(HWND,UINT);
API DWORD WINAPI GetSysColor(int);
API DWORD WINAPI GetTextColor(HDC);
API DWORD WINAPI GetBkColor(HDC);
API HGDIOBJ WINAPI GetStockObject(int);
API int WINAPI GetObjectW(HGDIOBJ,int,void *);
API BOOL WINAPI GetTextMetricsW(HDC,TEXTMETRICW *);
API LRESULT WINAPI DefWindowProcW(HWND,UINT,WPARAM,LPARAM);
API BOOL WINAPI DestroyWindow(HWND);
API void WINAPI PostQuitMessage(int);
API ATOM WINAPI RegisterClassW(const WNDCLASSW *);
API HWND WINAPI CreateWindowExW(DWORD,const WCHAR *,const WCHAR *,DWORD,int,int,int,int,HWND,HANDLE,HINSTANCE,void *);
API ULONG_PTR WINAPI SetTimer(HWND,ULONG_PTR,UINT,void *);
API BOOL WINAPI GetMessageW(MSG *,HWND,UINT,UINT);
API BOOL WINAPI TranslateMessage(const MSG *);
API LRESULT WINAPI DispatchMessageW(const MSG *);
#endif
