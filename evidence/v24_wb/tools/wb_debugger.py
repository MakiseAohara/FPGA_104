"""Use the existing MERGE14 VIO/LA; no FPGA programming or firmware writes."""
import argparse,datetime,json,logging,os,sys,time,traceback
from pathlib import Path
sys.dont_write_bytecode=True
os.environ.setdefault('EFINITY_USER_DIR',str(Path(os.environ['LOCALAPPDATA'])/'efinity').replace('\\','/'))
os.environ.setdefault('EFINITY_USER_DIR_INI',os.environ['EFINITY_USER_DIR']+'/user_dir.ini')
os.environ.setdefault('EFXPT_HOME','D:/Efinity/2026.1/pt')
os.environ.setdefault('EFXIPM_HOME','D:/Efinity/2026.1/ipm')
sys.path[:0]=[r'D:\Efinity\2026.1\debugger\bin',r'D:\Efinity\2026.1\pgm\bin']
from efx_dbg.define import DebugProfileDecoder
from efx_dbg.jtag import JtagManager
from pyftdi.bits import BitSequence

def ts():return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(timespec='milliseconds')
def profile():
    return {'debug_cores':[
        {'name':'vio0','type':'vio','uuid':'d2d3643a7f1e49a3a7f48b242e104fdd','probes':[
            {'name':'r_gain','width':16,'init':'0x118'},{'name':'g_gain','width':16,'init':'0xe8'},
            {'name':'b_gain','width':16,'init':'0x158'},{'name':'gamma_sel','width':1,'init':'0x0'}]},
        {'name':'la0','type':'la','uuid':'40fc40c15a7b4e5392113defb86d2a4c','probes':[
            {'name':'ch0_g','width':8,'probe_type':1},{'name':'ch0_b','width':8,'probe_type':1},
            {'name':'ch0_de','width':1,'probe_type':1},{'name':'cal_done','width':1,'probe_type':1}],
         'data_depth':1024,'trigin_en':False,'trigout_en':False,'capture_control':False,'input_pipeline':1,'auto_inserted':False}],
        'session':{'debug_widget':[],'wizard':{}}}

def main(a):
    a.out.mkdir(parents=True,exist_ok=True)
    logging.basicConfig(level=logging.ERROR)
    result={'started_wall':ts(),'board_programming':False,'firmware_writes':False,'camera_writes':False,
            'baseline_vio_from_bitstream_init':[280,232,344,0],'vio_output_hardware_readback':False,
            'captures':[],'attempts':[]}
    manager=JtagManager();session=debug=None
    try:
        for k in range(1,4):
            try:
                result['attempts'].append({'attempt':k,'wall':ts()})
                session=manager.config_jtag(url='hiftdi://0x0403:0x6011/1',tap='efx_ti',freq=3e6)
                break
            except Exception as e:
                result['attempts'][-1]['error']=repr(e)
                print('CONNECT_ERROR',k,repr(e),flush=True)
                if k==3:raise
                time.sleep(1)
        p=profile();(a.out/'debug_profile.json').write_text(json.dumps(p,indent=2)+'\n',encoding='utf-8')
        debug=manager.config_debug(session,json.loads(json.dumps(p),cls=DebugProfileDecoder))
        manager.validate_debug_cores(debug)
        result['validated_uuids']={name:controller.read_uuid() for name,controller in debug.get_controllers()}
        print('DEBUG_UUID_VALIDATED',result['validated_uuids'],flush=True)
        vio=debug.get_controller_by_name('vio0')
        if a.gains:
            vals=a.gains+[0]
            if any(v<128 or v>768 for v in vals[:3]):raise ValueError('Gain outside trial bounds [128,768]')
            vio.set_probe_out([BitSequence(v,length=w) for v,w in zip(vals,[16,16,16,1])])
            vio.write(packetized=True)
            result['vio_commanded']=vals
            result['vio_commit_wall']=ts()
            print('VIO_COMMITTED',vals,flush=True)
        la=debug.get_controller_by_name('la0')
        la.select_probes([False,False,False,False])
        la.set_property('trig_pos',512)
        la.set_property('window_depth',1024);la.set_property('num_window',1)
        la.set_window_regs(10,1)
        for k in range(a.captures):
            la.run_trig(imdt=True)
            deadline=time.monotonic()+5
            state=''
            while time.monotonic()<deadline:
                state=la.get_state()
                if state=='FULL':break
                time.sleep(.02)
            if state!='FULL':raise TimeoutError('LA capture state='+state)
            data=la.read()
            rows=[]
            for n,item in enumerate(data):
                rows.append({'i':n,'ch0_g':int(item[0:8]),'ch0_b':int(item[8:16]),'de':int(item[16:17]),'cal_done':int(item[17:18])})
            capture={'wall':ts(),'samples':rows}
            path=a.out/('raw_capture_%03d.json'%k)
            path.write_text(json.dumps(capture,separators=(',',':'))+'\n',encoding='utf-8')
            result['captures'].append({'file':path.name,'wall':capture['wall'],'samples':len(rows),'de_samples':sum(r['de'] for r in rows)})
            print('CAPTURE',k,'samples',len(rows),'active',result['captures'][-1]['de_samples'],flush=True)
            time.sleep(.067+(k%7)*.011)
    except Exception as e:
        result['error']=repr(e)
        (a.out/'FAILED.md').write_text('# White-balance debugger interruption\n\n'+repr(e)+'\n',encoding='utf-8')
        print(traceback.format_exc(),flush=True)
    finally:
        result['ended_wall']=ts()
        (a.out/'debugger_status.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        if session:
            try:
                if debug:manager.unconfig_debug(debug)
                session.detach_engine().close()
            except Exception as e:print('CLOSE_NOTE',repr(e),flush=True)
    return int('error' in result)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--captures',type=int,default=12);p.add_argument('--gains',type=lambda s:int(s,0),nargs=3)
    raise SystemExit(main(p.parse_args()))
