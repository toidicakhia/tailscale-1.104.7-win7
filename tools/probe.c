/* Launch a GUI, poll its module list until it dies, print the last snapshot. */
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>

typedef struct { ULONG_PTR base; DWORD size; char name[64]; } Mod;

static int enumerate(DWORD pid, Mod *out, int max) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return -1;
    MODULEENTRY32W me;
    me.dwSize = sizeof(me);
    int n = 0;
    if (Module32FirstW(snap, &me)) {
        do {
            if (n >= max) break;
            out[n].base = (ULONG_PTR)me.modBaseAddr;
            out[n].size = me.modBaseSize;
            WideCharToMultiByte(CP_ACP, 0, me.szModule, -1, out[n].name, 64, NULL, NULL);
            n++;
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
    return n;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    static wchar_t cmd[4096];
    cmd[0] = 0;
    for (int i = 1; i < argc; i++) {
        if (i > 1) wcscat(cmd, L" ");
        wchar_t w[1024];
        MultiByteToWideChar(CP_ACP, 0, argv[i], -1, w, 1024);
        wcscat(cmd, L"\"");
        wcscat(cmd, w);
        wcscat(cmd, L"\"");
    }

    /* Keep the child from inheriting our console/pipe handles: otherwise a
       surviving GUI holds the caller's stdout pipe open after probe exits. */
    SetHandleInformation(GetStdHandle(STD_INPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(GetStdHandle(STD_ERROR_HANDLE), HANDLE_FLAG_INHERIT, 0);

    WCHAR tempDir[MAX_PATH];
    WCHAR errPath[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, tempDir) ||
        !GetTempFileNameW(tempDir, L"tsprobe", 0, errPath)) {
        printf("temp file %lu\n", GetLastError());
        return 5;
    }

    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE hErr = CreateFileW(errPath,
                              GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = hErr;
    si.hStdError = hErr;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                        NULL, NULL, &si, &pi)) {
        printf("CreateProcess %lu\n", GetLastError());
        return 4;
    }
    printf("pid=%lu\n", (unsigned long)pi.dwProcessId);

    static Mod best[256];
    static Mod cur[256];
    int bestn = 0;
    DWORD timeout = 20000;
    const char *tenv = getenv("PROBE_TIMEOUT_MS");
    if (tenv) timeout = (DWORD)atoi(tenv);
    DWORD start = GetTickCount();
    for (;;) {
        int n = enumerate(pi.dwProcessId, cur, 256);
        if (n > 0) {
            memcpy(best, cur, sizeof(Mod) * n);
            bestn = n;
        }
        if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
        if (GetTickCount() - start > timeout) break;
        Sleep(1);
    }
    DWORD elapsed = GetTickCount() - start;
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    int killed = 0;
    if (code == STILL_ACTIVE) {
        TerminateProcess(pi.hProcess, 0xDEAD);
        WaitForSingleObject(pi.hProcess, 2000);
        GetExitCodeProcess(pi.hProcess, &code);
        killed = 1;
    }
    printf("exit=%lu elapsed=%lums snapshots_modules=%d killed=%d\n",
           (unsigned long)code, (unsigned long)elapsed, bestn, killed);

    ULONG_PTR crash = 0;
    FILE *f = _wfopen(errPath, L"r");
    if (f) {
        static char buf[65536];
        size_t got = fread(buf, 1, sizeof(buf) - 1, f);
        buf[got] = 0;
        fclose(f);
        char *p = strstr(buf, "Exception 0xc0000005");
        if (!p) p = strstr(buf, "Exception 0xC0000005");
        if (p) {
            unsigned long long code = 0, info0 = 0, addr = 0, pc = 0;
            if (sscanf(p, "Exception %llx %llx %llx %llx", &code, &info0, &addr, &pc) == 4) {
                printf("parsed exception code=%#llx info0=%#llx addr=%#llx pc=%#llx\n",
                       code, info0, addr, pc);
                crash = (ULONG_PTR)pc;
            }
        }
    }
    for (int i = 0; i < bestn; i++) {
        int hit = crash && crash >= best[i].base && crash < best[i].base + best[i].size;
        printf("%s%p %08lx %s%s\n", hit ? "HIT " : "MOD ", (void *)best[i].base,
               (unsigned long)best[i].size, best[i].name,
               hit ? "" : "");
        if (hit)
            printf("  crash=%p offset=%#llx\n", (void *)crash,
                   (unsigned long long)(crash - best[i].base));
    }
    DeleteFileW(errPath);
    return 0;
}
