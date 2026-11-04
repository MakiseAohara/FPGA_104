"""Isolated v7 flow: map -> preliminary PNR -> interface -> final PNR -> bit.

Never programs hardware. Each invocation requires a fresh source copy.
"""
import argparse
import csv
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET


def read_timing_summary(path):
    timing=path.read_text(encoding='utf8',errors='replace')
    setup=timing.split('Setup (Max) Clock Relationship',1)[1].split('Hold (Min) Clock Relationship',1)[0]
    hold=timing.split('Hold (Min) Clock Relationship',1)[1].split('Clock Relationship Summary (end)',1)[0]
    pattern=r'^\s*\S+\s+\S+\s+-?\d+\.\d+\s+(-?\d+\.\d+)\s+\('
    setup_slacks=[float(s) for s in re.findall(pattern,setup,re.M)]
    hold_slacks=[float(s) for s in re.findall(pattern,hold,re.M)]
    if not setup_slacks or not hold_slacks:raise RuntimeError('Final timing summary not found')
    return {'final_setup_min_ns':min(setup_slacks),'final_hold_min_ns':min(hold_slacks),
        'final_setup_domain_pairs':len(setup_slacks),'final_hold_domain_pairs':len(hold_slacks)}


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--work',type=Path,required=True)
    ap.add_argument('--tag',required=True)
    ap.add_argument('--efinity-home',type=Path,required=True)
    ap.add_argument('--log-root',type=Path,required=True)
    ap.add_argument('--project-file',default='ti60f225_oob.xml')
    ap.add_argument('--minimum-top-ports',type=int,default=40,
        help='Port parser guard; smaller isolated projects must set this explicitly.')
    ap.add_argument('--use-generated-sdc',action='store_true',
        help='Use freshly generated periphery timing for an isolated project.')
    ap.add_argument('--input-clock-period',action='append',default=[],metavar='NAME=NS',
        help='Resolve an external input clock period placeholder in generated SDC.')
    ap.add_argument('--require-assigned-ports',action='store_true',
        help='Reject unassigned core IO instead of allowing random placements.')
    ap.add_argument('--resume-interface',action='store_true',
        help='Continue this same source variant after successful preliminary PNR.')
    a=ap.parse_args()
    clock_periods={}
    for item in a.input_clock_period:
        match=re.fullmatch(r'(\w+)=([0-9]+(?:\.[0-9]+)?)',item)
        if not match or float(match[2])<=0:ap.error('Expected input clock NAME=positive_period_ns')
        clock_periods[match[1]]=match[2]
    work=a.work.absolute();efi=a.efinity_home.absolute()
    ns={'e':'http://www.efinixinc.com/enf_proj'}
    xml=work/a.project_file
    root=ET.parse(xml).getroot()
    name=root.attrib['name']; top=root.find('e:design_info/e:top_module',ns).attrib['name']
    logs=a.log_root.absolute()/a.tag
    out=work/'out';syn=work/'work_syn';pnrwork=work/'work_pnr'
    if a.resume_interface:
        vdb=out/(name+'.vdb')
        if not vdb.exists() or not (logs/'2-pnr-preliminary.log').exists():
            ap.error('Resume requires the same successful preliminary build.')
        sources=[xml,*[work/f.attrib['name'] for f in root.findall('e:design_info/e:design_file',ns)],
                 *work.glob('*.hex'),*work.glob('*.mem')]
        if any(p.stat().st_mtime>vdb.stat().st_mtime for p in sources
               if 'work_' not in str(p.relative_to(work))):
            ap.error('Source changed since synthesis; create a new variant.')
    else:
        for target in [out,syn,pnrwork,work/'outflow',logs]:
            if target.exists(): ap.error(f'Choose a fresh project/tag; preserving existing {target}')
        for target in [out,syn,pnrwork,logs]:target.mkdir(parents=True)
    env=os.environ.copy()
    # Some desktop tool environments omit this Windows variable. The bundled
    # x64 Python otherwise reports an empty machine and cannot import PT runtime.
    env.setdefault('PROCESSOR_ARCHITECTURE',platform.machine() or 'AMD64')
    for key,rel in [('EFINITY_HOME',''),('EFXPT_HOME','pt'),('EFXPGM_HOME','pgm'),
        ('EFXDBG_HOME','debugger'),('EFXIPM_HOME','ipm'),('PYTHONHOME','python311')]:
        env[key]=(efi/rel).as_posix()
    user=Path(env['LOCALAPPDATA'])/'efinity'
    env['EFINITY_USER_DIR']=user.as_posix()
    env['EFINITY_USER_DIR_INI']=(user/'user_dir.ini').as_posix()
    env['QT_PLUGIN_PATH']=(efi/'bin').as_posix()
    env['QT_QPA_PLATFORM_PLUGIN_PATH']=(efi/'python311/platforms').as_posix()
    env['PATH']=os.pathsep.join(str(efi/d) for d in
        ['python311/bin','bin','pgm/bin','debugger/bin','scripts'])+os.pathsep+env['PATH']
    commands=json.loads((logs/'commands.json').read_text()) if a.resume_interface else []
    def run(stage,cmd):
        cmd=list(map(str,cmd));commands.append({'stage':stage,'argv':cmd})
        (logs/'commands.json').write_text(json.dumps(commands,indent=2),encoding='utf8')
        print(stage,flush=True)
        with (logs/(stage+'.log')).open('w',encoding='utf8') as log:
            r=subprocess.run(cmd,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(f'{stage} exit={r.returncode}; see {logs}')
    inc=[work]
    for p in root.findall('e:synthesis/e:param',ns):
        if p.attrib['name']=='include':inc.append(work/p.attrib['value'])
    if not a.resume_interface:
        run('1-map',[efi/'bin/efx_map.exe','--project-xml',xml,'--project',name,'--root',top,
            '--device','Ti60F225','--family','Titanium','--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008',
            '--work-dir',syn,'--output-dir',out,*[x for d in inc for x in ['--I',d]]])
    pnr=[efi/'bin/efx_pnr.exe','--prj',xml,'--circuit',name,'--family','Titanium',
        '--device','Ti60F225','--operating_conditions','I3','--pack','--place','--route',
        '--vdb_file',out/(name+'.vdb'),'--use_vdb_file','on',
        '--place_file',out/(name+'.place'),'--route_file',out/(name+'.troutingtraces'),
        '--optimization_level','TIMING_3','--seed','0','--placer_effort_level','2',
        '--max_threads','-1','--beneficial_skew','on','--print_critical_path','10',
        '--work_dir',pnrwork,'--output_dir',out,'--timing_analysis','on',
        '--sdc_file',work/(name+'.sdc')]
    if not a.resume_interface:run('2-pnr-preliminary',pnr)
    run('3-interface',[efi/'python311/bin/python.exe',efi/'scripts/efx_run.py',name,
        '--prj','-f','interface','--output_dir',out])
    if a.use_generated_sdc:
        generated_sdc=out/(name+'.pt.sdc')
        if not generated_sdc.is_file():raise RuntimeError('Generated SDC missing')
        shutil.copy2(work/(name+'.sdc'),logs/'preliminary.sdc')
        sdc=generated_sdc.read_text(encoding='utf8')
        for clock,period in clock_periods.items():
            sdc=re.sub(r'(create_clock\s+-period\s+)<USER_PERIOD>(\s+-name\s+'+re.escape(clock)+r'\b)',
                       lambda m:m[1]+period+m[2],sdc)
        if '<USER_PERIOD>' in sdc:raise RuntimeError('Generated SDC contains an unresolved input clock period')
        (work/(name+'.sdc')).write_text(sdc,encoding='utf8')
    # Parse attributed ANSI port declarations; retain JTAG and clock assignments.
    text=(work/'rtl'/(top+'.v')).read_text(encoding='utf8')
    text=re.sub(r'/\*.*?\*/|//[^\n]*|\(\*.*?\*\)','',text,flags=re.S)
    header=text[text.index('module '):].split('\n);',1)[0]
    names=set(re.findall(r'\b(?:input|output|inout)\s+(?:(?:wire|reg)\s+)?(?:\[[^]]+\]\s*)?(\w+)',header))
    if a.minimum_top_ports<1 or len(names)<a.minimum_top_ports:
        raise RuntimeError('Top-level port parser found too few ports')
    raw=out/(name+'.interface.csv')
    kept=[];dropped=[]
    for line in raw.read_text(encoding='utf-8-sig').splitlines():
        fields=next(csv.reader([line]))
        if fields and re.match(r'^(required|optional)\b',fields[0].strip()):
            sig=fields[-1].strip()
            if sig not in ['__vcc__','__gnd__'] and re.sub(r'\[\d+\]$','',sig) not in names:
                dropped.append(line);continue
        kept.append(line)
    interface=out/(name+'.interface.csv')
    interface.write_text('\n'.join(kept)+'\n',encoding='utf8')
    (logs/'4-interface-dropped.log').write_text('\n'.join(dropped),encoding='utf8')
    run('5-pnr-final',pnr+['--sync_file',interface])
    final=(logs/'5-pnr-final.log').read_text(encoding='utf8',errors='replace')
    invalid=final.count('No valid pin(s) found for clock')
    if invalid:raise RuntimeError(f'Invalid SDC clocks: {invalid}; bit generation blocked')
    unassigned=re.findall(r'IO cell "([^"]+)" has no assigned placement',final)
    if a.require_assigned_ports and unassigned:
        raise RuntimeError('Unassigned core IO: '+', '.join(unassigned))
    lbfs=list(pnrwork.glob('*.lbf'))
    if len(lbfs)!=1:raise RuntimeError(f'Expected one new LBF, found {lbfs}')
    run('6-bitgen',[efi/'bin/efx_pgm.exe','--project-xml',xml,'--source',lbfs[0],
        '--dest',logs/(a.tag+'.hex'),'--family','Titanium','--device','Ti60F225',
        '--mode','active','--width','1','--periph',out/(name+'.lpf'),
        '--interface_designer_settings',out/(name+'_or.ini')])
    bit=logs/(a.tag+'.bit')
    if not bit.exists():raise RuntimeError('Bitstream not generated')
    timing_lines=[l.strip() for l in final.splitlines() if re.search(
        r'XLRs:|Memory Blocks:|DSP Blocks:|hold \(min\)|setup \(max\)|slack',l,re.I)]
    report={'bit':str(bit),'bytes':bit.stat().st_size,'sha256':hashlib.sha256(bit.read_bytes()).hexdigest(),
        'invalid_sdc_clocks':invalid,'unmatched_clock_warnings':final.count('No clocks matched'),
        'unassigned_core_io':unassigned,
        'placement_hold_warning_count':len(re.findall(r'WARNING.*hold \(min\)',final)),
        **read_timing_summary(out/(name+'.timing.rpt')),
        'timing_and_resource_lines':timing_lines,'board_verified':False,
        'note':'Bit generation does not certify timing closure or board operation; inspect timing lines.'}
    (logs/'result.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':main()
