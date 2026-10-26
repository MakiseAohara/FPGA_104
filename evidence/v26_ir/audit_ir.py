"""Read-only provenance and v25 IR field audit; no hardware access."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("--archive", type=Path, required=True)
parser.add_argument("--repo", type=Path, required=True)
args = parser.parse_args()
out = Path(__file__).resolve().parent
sha = hashlib.sha256(args.archive.read_bytes()).hexdigest()
assert sha.upper() == "FCC93E5543D0FCBE519CCB3F1449B0E6AED1205DDB6401A02D350E22801DC6DB"
selections = {
    "rtl/v7/mmt/v7_mmt_core.v": [(99,106), (119,140), (174,202), (219,241)],
    "rtl/v7/mmt/v7_ir_proc.v": [(34,49), (51,75)],
    "rtl/v7/mmt/v7_apb_ext.v": [(75,81), (189,197)],
    "rtl/v7/mmt/mmt_mlx90640_ctrl.v": [(45,65), (337,345)],
    "rtl/v7/mmt/mmt_sensor_subsystem.v": [(207,222), (247,257)],
    "rtl/ti60f225_oob_top.v": [(852,858), (920,940), (1019,1020), (1473,1498)],
    "ti60f225_oob.peri.xml": [(293,301)],
}
sources = {}
with zipfile.ZipFile(args.archive) as archive:
    for name, ranges in selections.items():
        data = archive.read(name)
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = data.decode("gb18030", errors="replace")
        lines = text.splitlines()
        sources[name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                             excerpts=[dict(start=a, end=b, lines=[f"{i}: {lines[i-1]}" for i in range(a,min(b,len(lines))+1)]) for a,b in ranges])
kv = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
log = args.repo / "evidence/v25_gate/log_v25_gate.log"
counts = {name:Counter() for name in ("body", "irhot", "sht", "rh", "ir_upd")}
tags = Counter()
for raw in log.read_bytes().decode("utf-8").split("\n"):
    text = raw.split("\t",1)[-1].strip()
    fields = dict(kv.findall(text))
    tag = text.split(" ",1)[0]
    tags[tag] += 1
    for name in counts:
        expected = "MMT_DEC" if name == "irhot" else "MMT_LP"
        if tag == expected and name in fields:
            counts[name][int(fields[name])] += 1
result = dict(archive_sha256=sha, source_scope="frozen MERGE14 source archive and v19 firmware; no board access",
              v25_log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
              dec_records=tags["MMT_DEC"], lp_records=tags["MMT_LP"],
              fields={name:dict(sorted(values.items())) for name,values in counts.items()},
              sources=sources, firmware_source_sha256=hashlib.sha256((args.repo/"evidence/v19/main_live19.cc").read_bytes()).hexdigest(),
              hardware_access=False, firmware_built=False, firmware_flashed=False, rtl_modified=False)
(out / "source_audit.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8",newline="\n")
print(json.dumps({"dec":result["dec_records"], "lp":result["lp_records"], "body":result["fields"]["body"],
                  "irhot":result["fields"]["irhot"], "sht_distinct":len(counts["sht"]),
                  "ir_upd_distinct":len(counts["ir_upd"])},ensure_ascii=False))
