"""Exercise MERGE14's actual debayer sources with synthetic Bayer fields.

Reuses the repository stimulus, binds Q8.8 gains explicitly, and observes named
R/G/B planes rather than guessing the packed bus order from an older comment.
No production RTL is edited; no board or bitstream build is involved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


SOURCES = ["rtl/true_dual_port_ram.v", "rtl/debayer/rgb_gain_v1.v",
           "rtl/debayer/line_buffer.v", "rtl/debayer/raw_to_rgb.v",
           "rtl/debayer/debayer_top_2to1.v"]


def run(a):
    a.work.mkdir(parents=True, exist_ok=True)
    a.out.mkdir(parents=True, exist_ok=True)
    z = zipfile.ZipFile(a.source_zip)
    for name in SOURCES:
        path = a.work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(z.read(name))
    template = (a.repo / "sim/debayer/tb_debayer.v").read_text(encoding="utf-8-sig")
    template = template.replace("wire [47:0] rgb_data;", "wire [47:0] rgb_data;\n    wire [15:0] r_plane, g_plane, b_plane;")
    template = template.replace(".raw_datax4_i (raw_data),", ".raw_datax4_i (raw_data),\n        .r_gain(`GAIN_R), .g_gain(`GAIN_G), .b_gain(`GAIN_B),\n        .rgb_rout(r_plane), .rgb_gout(g_plane), .rgb_bout(b_plane),")
    for plane, channel in (("r_plane", "r"), ("g_plane", "g"), ("b_plane", "b")):
        for lane, bits in ((0, "7:0"), (1, "15:8")):
            template = re.sub(r"(c%d%s\[cap_line\]\[cap_col\]\s*<=\s*)rgb_data\[\d+:\d+\]" % (lane, channel),
                              r"\g<1>" + plane + "[" + bits + "]", template)
    # Keep low-valued fields so channel-gain routing is visible without clipping.
    start, end = template.index("function [7:0] pix_field;"), template.index("endfunction", template.index("function [7:0] pix_field;"))
    template = template[:start] + template[start:end].replace("8'd255", "8'd64") + template[end:]
    template = template.replace("all gains 3'd4 (= x1.0 pass-through)", "explicit Q8.8 gains; named R/G/B planes")
    tb = a.work / "tb_merge14.v"
    tb.write_text(template, encoding="utf-8", newline="\n")
    env = os.environ.copy()
    env["PATH"] = str(a.iverilog.parent) + os.pathsep + env.get("PATH", "")
    records = []
    cases = {}
    variants = {"unity": (256,256,256), "merge14": (280,232,344),
                "r_port_x2": (512,256,256), "b_port_x2": (256,256,512)}
    for label, gains in variants.items():
        vvp = a.work / (label + ".vvp")
        command = [str(a.iverilog), "-g2012", "-s", "tb_debayer", "-o", str(vvp)]
        command += ["-DGAIN_%s=16'd%d" % (channel, gain) for channel, gain in zip("RGB", gains)]
        command += [str(a.work / name) for name in SOURCES] + [str(tb)]
        build = subprocess.run(command, capture_output=True, env=env, timeout=60)
        (a.out / (label + "_build.log")).write_bytes(build.stdout + build.stderr)
        build.check_returncode()
        sim = subprocess.run([str(a.iverilog.parent / "vvp.exe"), str(vvp)], capture_output=True, env=env, timeout=60)
        log = sim.stdout.decode("utf-8", errors="replace") + sim.stderr.decode("utf-8", errors="replace")
        (a.out / (label + "_simulation.log")).write_text(log, encoding="utf-8", newline="\n")
        sim.check_returncode()
        if "GLOBAL TIMEOUT" in log or "DEBAYER TEST DONE" not in log:
            raise RuntimeError(label + " simulation did not complete")
        table = {}
        pattern = r"PACK=(\d) phase=(\w+) field=(\w+).*?sumR=\s*(\d+)\s+sumG=\s*(\d+)\s+sumB=\s*(\d+).*?=>\s*(\S+)"
        for match in re.finditer(pattern, log):
            pack, phase, field = match.group(1,2,3)
            table[(pack, phase, field)] = {"sum_rgb": list(map(int, match.group(4,5,6))), "dominant": match.group(7)}
        if len(table) != 24:
            raise RuntimeError(label + " expected 24 colour cases, got " + str(len(table)))
        cases[label] = [{"pack": key[0], "phase": key[1], "field": key[2], **value} for key,value in table.items()]
        records.append({"variant": label, "gains_q8_8": gains, "parsed_colour_cases": len(table)})
    numeric_vvp=a.work/"gain_numeric.vvp"
    numeric_build=subprocess.run([str(a.iverilog),"-g2012","-s","tb_gain_numeric","-o",str(numeric_vvp),
                                  str(a.work/"rtl/debayer/rgb_gain_v1.v"),str(Path(__file__).with_name("tb_gain_numeric.v"))],
                                 capture_output=True,env=env,timeout=60)
    (a.out/"numeric_gain_build.log").write_bytes(numeric_build.stdout+numeric_build.stderr)
    numeric_build.check_returncode()
    numeric_run=subprocess.run([str(a.iverilog.parent/"vvp.exe"),str(numeric_vvp)],capture_output=True,env=env,timeout=60)
    (a.out/"numeric_gain.log").write_bytes(numeric_run.stdout+numeric_run.stderr)
    numeric_run.check_returncode()
    numeric_match=re.search(rb"NUMERIC_GAIN_CHECKS=(\d+) CHANNEL_VALUES=(\d+)",numeric_run.stdout)
    if not numeric_match or int(numeric_match[1])!=2048:
        raise RuntimeError("Numeric gain simulation incomplete")
    result = {"source_zip_sha256": hashlib.sha256(a.source_zip.read_bytes()).hexdigest(),
              "source_hashes": {name: hashlib.sha256(z.read(name)).hexdigest() for name in SOURCES},
              "original_rtl_modified": False, "board_access": False,
              "observed_outputs": "named rgb_rout/rgb_gout/rgb_bout", "variants": records,
              "colour_cases": cases,"numeric_word_checks":int(numeric_match[1]),
              "numeric_channel_values":int(numeric_match[2]),
              "limitations": ["Synthetic Bayer fields do not establish the sensor's physical Bayer phase or neutral white point.",
                              "Display-path gamma/OSD/encoder are outside this debayer simulation."]}
    (a.out / "colour_rtl.json").write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8", newline="\n")
    print(json.dumps(records))


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source-zip", type=Path, required=True)
    p.add_argument("--repo", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--iverilog", type=Path, default=Path(r"D:\iverilog\bin\iverilog.exe"))
    run(p.parse_args())
