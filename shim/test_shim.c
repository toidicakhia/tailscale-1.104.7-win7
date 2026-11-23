#include <windows.h>
#include <stdio.h>

typedef BOOL (WINAPI *ProcessPrngFn)(PBYTE, SIZE_T);

int main(int argc, char **argv) {
    WCHAR path[MAX_PATH];
    if (argc > 1) {
        MultiByteToWideChar(CP_ACP, 0, argv[1], -1, path, MAX_PATH);
    } else {
        lstrcpynW(path, L"tsbcryptprng_win.dll", MAX_PATH);
    }
    HMODULE h = LoadLibraryW(path);
    if (h == NULL) {
        printf("LoadLibrary failed: %lu\n", GetLastError());
        return 1;
    }
    ProcessPrngFn fn = (ProcessPrngFn)GetProcAddress(h, "ProcessPrng");
    if (fn == NULL) {
        printf("GetProcAddress failed: %lu\n", GetLastError());
        return 2;
    }
    BYTE buf[32];
    if (!fn(buf, sizeof(buf))) {
        printf("ProcessPrng failed\n");
        return 3;
    }
    for (int i = 0; i < (int)sizeof(buf); i++) {
        printf("%02x", buf[i]);
    }
    printf("\n");
    return 0;
}
