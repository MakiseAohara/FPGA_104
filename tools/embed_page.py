"""Generate the FPGA page bytes from the same HTML served by the PC."""
from pathlib import Path
root=Path(__file__).absolute().parents[1]
data=(root/'tools/page.html').read_bytes()
target=root/'evidence/v30_mot/page_html.h'
lines=[','.join(str(v) for v in data[i:i+32]) for i in range(0,len(data),32)]
target.write_text('#ifndef MMT_PAGE_HTML_H\n#define MMT_PAGE_HTML_H\n'
                  'static const unsigned char page_html[]={\n'+',\n'.join(lines)+'\n};\n'
                  '#define PAGE_HTML_LEN '+str(len(data))+'\n#endif\n',encoding='ascii')
print('Embedded page:',len(data),'bytes')
