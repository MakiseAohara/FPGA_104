import os,json,subprocess,hashlib,importlib.util
from pathlib import Path
work=Path(r'D:/eth_build/netfix04_rxq2');logs=Path(r'D:/FPGA/netfix04/evidence/network_20261104/builds/netfix04_rxq2');efi=Path(r'D:/Efinity/2026.1')
env=os.environ.copy()
for key,rel in [('EFINITY_HOME',''),('EFXPT_HOME','pt'),('EFXPGM_HOME','pgm'),('EFXDBG_HOME','debugger'),('EFXIPM_HOME','ipm'),('PYTHONHOME','python311')]:env[key]=(efi/rel).as_posix()
env['PROCESSOR_ARCHITECTURE']='AMD64';env['EFINITY_USER_DIR']=(Path(env['LOCALAPPDATA'])/'efinity').as_posix();env['EFINITY_USER_DIR_INI']=env['EFINITY_USER_DIR']+'/user_dir.ini'
env['PATH']=';'.join(str(efi/x) for x in ['python311/bin','bin','pgm/bin','debugger/bin','scripts'])+';'+env['PATH']
commands=json.loads((logs/'commands.json').read_text());cmd=commands[-1]['argv'];cmd[cmd.index('--seed')+1]='1'
(logs/'retry-command.json').write_text(json.dumps(cmd,indent=2))
with (logs/'5b-pnr-seed1.log').open('w') as f:r=subprocess.run(cmd,cwd=work,env=env,stdout=f,stderr=subprocess.STDOUT)
print('PNR_EXIT',r.returncode,flush=True)
if r.returncode:raise SystemExit(r.returncode)
lbf=list((work/'work_pnr').glob('*.lbf'));assert len(lbf)==1
cmd=[efi/'bin/efx_pgm.exe','--project-xml',work/'ti60f225_oob.xml','--source',lbf[0],'--dest',logs/'netfix04_rxq2_seed1.hex','--family','Titanium','--device','Ti60F225','--mode','active','--width','1','--periph',work/'out/ti60f225_oob.lpf','--interface_designer_settings',work/'out/ti60f225_oob_or.ini']
with (logs/'6-bitgen-seed1.log').open('w') as f:r=subprocess.run(list(map(str,cmd)),cwd=work,env=env,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0
bit=logs/'netfix04_rxq2_seed1.bit'
info={'bit':str(bit),'bytes':bit.stat().st_size,'sha256':hashlib.sha256(bit.read_bytes()).hexdigest(),'board_verified':False}
(logs/'result-seed1.json').write_text(json.dumps(info,indent=2));print(json.dumps(info),flush=True)
