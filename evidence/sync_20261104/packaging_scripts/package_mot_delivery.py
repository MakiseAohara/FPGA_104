from pathlib import Path
import difflib,hashlib,json,shutil,zipfile

workspace=Path(__file__).absolute().parents[2]
source=Path(r'D:\FPGA\motweb04')
baseline=Path(r'D:\FPGA\netfix04')
target=workspace/'outputs/mot_tracking_web_20261104'
target.mkdir(parents=True,exist_ok=True)
def copy_file(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
for name in ('tools','sw','submission','firmware'):
    shutil.copytree(source/name,target/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
copy_file(source/'README_MOT_WEB_20261104.md',target/'README.md')
core=source/'evidence/v30_mot'
for p in core.iterdir():
    if p.is_file():copy_file(p,target/'evidence/v30_mot'/p.name)
evidence=source/'evidence/mot_web_20261104'
for p in evidence.iterdir():
    if p.is_file() and p.suffix.lower() not in ('.obj','.lib','.exp','.exe'):
        copy_file(p,target/'evidence/mot_web_20261104'/p.name)
for name in ('replays','recordings','board_fw4','jtag_fw4'):
    shutil.copytree(evidence/name,target/'evidence/mot_web_20261104'/name,dirs_exist_ok=True)
# Default regeneration uses portable audited input; keep source index intact.
copy_file(evidence/'recordings_index.json',target/'evidence/mot_web_20261104/recordings_index_original_paths.json')
copy_file(evidence/'recordings_index_portable.json',target/'evidence/mot_web_20261104/recordings_index.json')
build=Path(r'D:\v30_build\out_motweb04_fw4')
for name in ('build_v30.log','link.log','size.txt','sha256.json','compile_commands.json'):
    copy_file(build/name,target/'evidence/firmware_build_fw4'/name)
copy_file(workspace/'work/mot-web-20261104/firmware4-build.log',target/'evidence/firmware_build_fw4/build_summary.log')
copy_file(workspace/'outputs/network_web_fix_20261104/tools/load_firmware.py',target/'tools/load_firmware.py')
copy_file(workspace/'outputs/fpga_onboard_verified_20261020/tools/flash_vendor.ps1',target/'tools/flash_vendor.ps1')

patch=[]
paths=[p for folder in ('tools','evidence/v30_mot') for p in (source/folder).iterdir()
       if p.is_file() and p.suffix in ('.py','.ps1','.cc','.h','.html')]
for p in sorted(paths):
    rel=p.relative_to(source).as_posix();old=baseline/rel
    before=old.read_text(encoding='utf8').splitlines(keepends=True) if old.exists() else []
    after=p.read_text(encoding='utf8').splitlines(keepends=True)
    patch.extend(difflib.unified_diff(before,after,fromfile='a/'+rel if old.exists() else '/dev/null',tofile='b/'+rel))
(target/'source_vs_netfix04.patch').write_text(''.join(patch),encoding='utf8')
manifest={'base_github_commit':'8965c881218f5cfa5b3d24c0baf954a792d6dc32',
          'source_project':str(source),'pc_url':'http://169.254.47.62:8090/',
          'board_url':'http://169.254.47.63/','offline_url':'http://127.0.0.1:8092/',
          'firmware':json.loads((source/'firmware/firmware_identity.json').read_text()),
          'manual_multi_person_test':False,'max_targets':2,'spi_flash_written':False,
          'files':{}}
for p in sorted(target.rglob('*')):
    if p.is_file() and p.name!='manifest.json':manifest['files'][p.relative_to(target).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
(target/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
archive=target.with_suffix('.zip')
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(target.rglob('*')):
        if p.is_file():z.write(p,arcname=str(Path(target.name)/p.relative_to(target)))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for required in ('README.md','firmware/tinyml_pdti8.bin','evidence/mot_web_20261104/live_links_verified.json','evidence/mot_web_20261104/ui_live_selftest.json','tools/page.html'):
        assert target.name+'/'+required in z.namelist()
print(json.dumps({'zip':str(archive),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'files':len(manifest['files'])},ensure_ascii=False))
