"""Read IDCODE and debug-core identity without controller soft resets."""
import argparse,json,sys,time
from pathlib import Path
import wb_debugger as wb
from efx_dbg.engine import DebugEngine
from efx_dbg.jtag import VioController,LogicNController
from efx_pgm.device_utils import DeviceUtils

p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--tap',default='efx_ti');p.add_argument('--freq',type=float,default=1e6);p.add_argument('--user',default='USER1');p.add_argument('--tap-initialize',action='store_true');p.add_argument('--idle-after-ir',action='store_true');a=p.parse_args()
a.out.parent.mkdir(parents=True,exist_ok=True)
m=wb.JtagManager();s=None
result={'wall':wb.ts(),'tap':a.tap,'user':a.user,'freq':a.freq,'soft_reset_sent':False,'gain_writes':False,'camera_writes':False}
try:
    s=m.config_jtag(url='hiftdi://0x0403:0x6011/1',tap=a.tap,freq=a.freq,user=a.user)
    if a.idle_after_ir:
        provider=s._jtag_engine._engine_provider
        original_write_ir=provider.write_ir
        def idle_write_ir(instruction):
            original_write_ir(instruction);provider.go_idle()
        provider.write_ir=idle_write_ir
        result['run_idle_after_ir']=True
    with s.get_engine() as eng:
        eng.write_ir(DeviceUtils.tap_to_instr(a.tap)['IDCODE'])
        result['device_idcode']='%08X'%int(eng.read_dr(32))
        if a.tap_initialize:
            eng.reset();eng.write_ir(DeviceUtils.tap_to_instr(a.tap)[a.user])
            eng.reset();eng.write_ir(DeviceUtils.tap_to_instr(a.tap)[a.user])
            result['tap_only_initialize']=True
    profile=json.loads(json.dumps(wb.profile()),cls=wb.DebugProfileDecoder)
    engine=DebugEngine(s,profile)
    result['cores']={}
    for spec,cls in zip(profile.list_cores(),[VioController,LogicNController]):
        ctrl=cls.__new__(cls);ctrl._engine=engine;ctrl._spec=spec
        received=ctrl.read_uuid()
        result['cores'][spec.get_name()]={'received':received,'expected':spec.get_uuid(),'version':ctrl.read_version()}
    print(json.dumps(result),flush=True)
except Exception as e:
    result['error']=repr(e);result['error_details']={k:str(v) for k,v in vars(e).items()}
    print(json.dumps(result),flush=True)
finally:
    if s:s.detach_engine().close()
    a.out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
