import msilib
import sys

PATH = r"D:\tailscale\work\tailscale-setup-1.104.7-amd64.msi"
OUT = r"D:\tailscale\work\msi_tables.txt"

TABLES = [
    "Property", "LaunchCondition", "Directory", "CreateFolder", "File",
    "Component", "Feature", "FeatureComponents", "Media",
    "ServiceInstall", "ServiceControl", "MsiServiceConfig",
    "MsiServiceConfigFailureActions", "MsiLockPermissionsEx",
    "Registry", "RemoveRegistry", "Shortcut", "Environment", "IniFile",
    "RemoveFile", "CustomAction", "InstallExecuteSequence",
    "InstallUISequence", "AdminExecuteSequence", "AdminUISequence",
    "AdvtExecuteSequence", "Upgrade", "MsiAssembly", "MsiAssemblyName",
    "Binary", "Icon", "Billboard", "Control", "Dialog",
]

db = msilib.OpenDatabase(PATH, msilib.MSIDBOPEN_READONLY)


def q(sql):
    v = db.OpenView(sql)
    v.Execute(None)
    rows = []
    while True:
        r = v.Fetch()
        if r is None:
            break
        rows.append(r)
    v.Close()
    return rows


# Map table -> ordered column names from _Columns.
cols = {}
for r in q("SELECT * FROM _Columns"):
    t = r.GetString(1)
    n = r.GetInteger(2)
    name = r.GetString(3)
    cols.setdefault(t, {})[n] = name

# List all tables for completeness.
all_tables = [r.GetString(1) for r in q("SELECT * FROM _Tables")]
all_tables.sort()

out = open(OUT, "w", encoding="utf-8")
out.write("TABLES (%d): %s\n" % (len(all_tables), ", ".join(all_tables)))

for table in TABLES:
    out.write("\n===== %s =====\n" % table)
    if table not in all_tables:
        out.write("(table absent)\n")
        continue
    try:
        rows = q("SELECT * FROM `%s`" % table)
    except Exception as e:
        out.write("(query failed: %s)\n" % e)
        continue
    if not rows:
        out.write("(empty)\n")
        continue
    names = cols.get(table, {})
    out.write("columns: %s\n" % ", ".join(names[k] for k in sorted(names)))
    for r in rows:
        n = r.GetFieldCount()
        parts = []
        for i in range(1, n + 1):
            name = names.get(i, "?%d" % i)
            s = ""
            iv = ""
            try:
                s = r.GetString(i)
            except Exception:
                pass
            try:
                iv = str(r.GetInteger(i))
            except Exception:
                pass
            # Prefer string form, but show integer for numeric columns.
            val = s if s != "" else iv
            parts.append("%s=%r" % (name, val))
        out.write(" | ".join(parts) + "\n")

out.close()
print("wrote", OUT)
