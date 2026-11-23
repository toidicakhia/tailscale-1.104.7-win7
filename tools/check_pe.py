import pefile, sys, os
for path in sys.argv[1:]:
    p = pefile.PE(path)
    oh = p.OPTIONAL_HEADER
    print("=====", os.path.basename(path), "size", os.path.getsize(path))
    print("machine", hex(p.FILE_HEADER.Machine), "OS", oh.MajorOperatingSystemVersion, oh.MinorOperatingSystemVersion, "SUB", oh.MajorSubsystemVersion, oh.MinorSubsystemVersion, "subsystem", oh.Subsystem, "checksum", hex(oh.CheckSum))
    print("dlls:", ", ".join(sorted(i.dll.decode(errors="replace") for i in getattr(p, "DIRECTORY_ENTRY_IMPORT", []))))
    funcs = []
    for i in getattr(p, "DIRECTORY_ENTRY_IMPORT", []):
        for x in i.imports:
            funcs.append(x.name.decode(errors="replace") if x.name else str(x.ordinal))
    print("nfuncs", len(funcs))
    suspects = ("waitonaddress", "wakebyaddress", "getsystemtimeprecise", "virtualalloc2", "setthreaddescription", "getdpiforwindow", "setprocessdpiawareness", "getsystemcpuset", "discardvirtualmemory", "offer virtualmemory", "getpacked", "createfile2", "copyfile2", "gettempath2")
    print("suspect:", ", ".join(sorted(set(f for f in funcs if any(k in f.lower() for k in suspects)))))
