// tsbcryptprng.dll - ProcessPrng compatibility shim for Windows 7.
//
// Go 1.27's runtime loads ProcessPrng from bcryptprimitives.dll. Windows 7
// ships bcryptprimitives.dll but not ProcessPrng (it arrived in Windows 8).
// The patched tailscale-ipn.exe loads this uniquely named DLL instead; it
// forwards to the real ProcessPrng when present and otherwise falls back to
// advapi32!SystemFunction036 (RtlGenRandom).

#include <windows.h>

typedef BOOL (WINAPI *ProcessPrngFn)(PBYTE, SIZE_T);
typedef BOOLEAN (WINAPI *RtlGenRandomFn)(PVOID, ULONG);

static ProcessPrngFn g_processPrng;
static RtlGenRandomFn g_rtlGenRandom;
static INIT_ONCE g_initOnce = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK InitShim(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    HMODULE bcrypt = LoadLibraryW(L"bcryptprimitives.dll");
    if (bcrypt != NULL) {
        g_processPrng = (ProcessPrngFn)GetProcAddress(bcrypt, "ProcessPrng");
        if (g_processPrng != NULL) {
            return TRUE;
        }
    }
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    if (advapi != NULL) {
        g_rtlGenRandom = (RtlGenRandomFn)GetProcAddress(advapi, "SystemFunction036");
    }
    return TRUE;
}

__declspec(dllexport) BOOL WINAPI ProcessPrng(PBYTE pbData, SIZE_T cbData) {
    InitOnceExecuteOnce(&g_initOnce, InitShim, NULL, NULL);
    if (g_processPrng != NULL) {
        return g_processPrng(pbData, cbData);
    }
    if (g_rtlGenRandom == NULL) {
        return FALSE;
    }
    while (cbData > 0) {
        ULONG chunk = cbData > 0xFFFFFFFFUL ? 0xFFFFFFFFUL : (ULONG)cbData;
        if (!g_rtlGenRandom(pbData, chunk)) {
            return FALSE;
        }
        pbData += chunk;
        cbData -= chunk;
    }
    return TRUE;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    return TRUE;
}
