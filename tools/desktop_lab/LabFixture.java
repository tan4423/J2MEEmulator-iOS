import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;

public final class LabFixture extends MIDlet {
    private static int logicProbe(int seed) {
        int v=seed;
        for(int i=0;i<4096;i++) {
            v=v*33+i;
            v^=v>>>7;
            v+=(i<<5)^0x55aa55aa;
        }
        return v;
    }
    protected void startApp() {
        if(logicProbe(0x12345678)!=-477686842)throw new RuntimeException("logic oracle mismatch");
        System.out.println("LAB_FIXTURE_LOGIC_PASS");
        try {
            String port=System.getProperty("jarbox.lab.test.port");
            if(port==null)throw new RuntimeException("test port absent");
            javax.microedition.io.SocketConnection c=(javax.microedition.io.SocketConnection)
                javax.microedition.io.Connector.open("socket://127.0.0.1:"+port);
            java.io.DataOutputStream out=c.openDataOutputStream();
            java.io.DataInputStream in=c.openDataInputStream();
            out.writeInt(0x12345678);out.flush();
            if(in.readInt()!=0x13572468)throw new RuntimeException("socket roundtrip");
            c.close();
            javax.microedition.rms.RecordStore rs=javax.microedition.rms.RecordStore.openRecordStore("LabProbe",true);
            byte[] data={4,5,6};int id=rs.addRecord(data,0,data.length);rs.closeRecordStore();
            rs=javax.microedition.rms.RecordStore.openRecordStore("LabProbe",false);
            byte[] got=rs.getRecord(id);if(got.length!=3||got[1]!=5)throw new RuntimeException("RMS roundtrip");
            rs.closeRecordStore();
            System.out.println("LAB_FIXTURE_TCP_RMS_PASS");
            // Real GC worker must run before the fixture stops.
            Thread.sleep(1250);
        }catch(Exception ex){throw new RuntimeException(ex.toString());}
        final boolean controlled="1".equals(System.getProperty("jarbox.lab.test.control"));
        final TextBox text=new TextBox(controlled?"chat":"Lab input",controlled?"":"a",8,TextField.ANY);
        final Command done=new Command("Done",Command.OK,1);
        text.addCommand(done);
        text.setCommandListener(new CommandListener(){
            public void commandAction(Command c,Displayable d){
                if(c!=done||!(controlled?"gm37":"ab").equals(text.getString()))throw new RuntimeException("desktop text/command roundtrip");
                System.out.println("LAB_FIXTURE_UI_PASS");
                Display.getDisplay(LabFixture.this).setCurrent(new Probe());
            }
        });
        Display.getDisplay(this).setCurrent(text);
    }
    protected void pauseApp() {}
    protected void destroyApp(boolean unconditional) {}
    final class Probe extends Canvas {
        private int s6;
        private boolean touched;
        private final boolean sink="1".equals(System.getProperty("jarbox.lab.test.sink"));
        protected void keyPressed(int key){if(sink&&key==-5)repaint();}
        private final boolean control="1".equals(System.getProperty("jarbox.lab.test.control"));
        protected void pointerPressed(int x,int y){if(control&&x==120&&y==137)touched=true;}
        protected void pointerReleased(int x,int y){if(control&&touched&&x==120&&y==137){System.out.println("LAB_FIXTURE_BACKGROUND_INPUT_PASS");notifyDestroyed();}}
        protected void paint(Graphics g) {
            s6++;
            if(!sink&&s6!=1)throw new RuntimeException("fixture state");
            if(sink)System.out.println("LAB_SINK_PAINT "+s6);
            if("1".equals(System.getProperty("jarbox.lab.test.map")))Class_hii.verify();

            Image im=Image.createImage(8,8);
            Graphics ig=im.getGraphics();
            ig.setColor(0x123456);
            ig.fillRect(0,0,8,8);
            int[] p=new int[64];
            im.getRGB(p,0,8,0,0,8,8);
            for(int v:p) if(v!=0xff123456) throw new RuntimeException("offscreen pixel mismatch");
            g.setColor(0xffffff);
            g.fillRect(0,0,getWidth(),getHeight());
            g.drawImage(im,0,0,Graphics.TOP|Graphics.LEFT);
            g.drawRegion(im,0,0,8,8,5,16,0,Graphics.TOP|Graphics.LEFT);
            g.setColor(0);
            g.drawString("LAB",0,16,Graphics.TOP|Graphics.LEFT);
            g.drawArc(0,20,12,12,0,180);
            g.drawRoundRect(15,20,12,12,4,4);
            g.fillRoundRect(30,20,12,12,4,4);
            g.fillArc(45,20,12,12,0,90);
            try {
                Image tall=Image.createImage("/lab-tall.png");
                if(tall.getWidth()!=24||tall.getHeight()!=3432)throw new RuntimeException("tall atlas dimensions");
                int[] atlasPixel=new int[1];
                tall.getRGB(atlasPixel,0,1,23,3431,1,1);
                if(atlasPixel[0]!=0xff336699)throw new RuntimeException("tall atlas last pixel");
                g.drawRegion(tall,0,3408,24,24,0,60,20,Graphics.TOP|Graphics.LEFT);
                System.out.println("LAB_FIXTURE_TALL_ATLAS_PASS");
            }catch(Exception e){throw new RuntimeException(e.toString());}
            Image check=Image.createImage(24,24);
            Graphics cg=check.getGraphics();
            cg.setColor(0x00aa00);cg.fillRoundRect(0,0,20,20,6,6);
            int[] rgb=new int[1];check.getRGB(rgb,0,1,10,10,1,1);
            if(rgb[0]!=0xff00aa00)throw new RuntimeException("rounded fill center");
            System.out.println("LAB_FIXTURE_SHAPES_PASS");
            System.out.println("LAB_FIXTURE_PIXEL_PASS");
            if(!control)notifyDestroyed();
        }
    }
}

/* Synthetic exact shape of the two original 17-byte map leaves. Not a
 * copied or modified game class. Run the same oracle in A, B and A2. */
final class Class_hii {
    private static int[] x3;
    private static char[] u3;
    private static int j1;
    private static int q3(int x,int y){try{return x3[y*j1+x];}catch(Exception e){return 1000;}}
    private static int m3(int x,int y){try{return u3[y*j1+x];}catch(Exception e){return 1000;}}
    private static void check(int a,int b){if(a!=b)throw new RuntimeException("map oracle mismatch "+a+" expected "+b);}
    static void verify(){
        x3=new int[]{-7,42,-2147483648,1000,123,-999};
        u3=new char[]{0,65535,32768,1000,123,65534};
        j1=3;
        int[] ints={-7,42,-2147483648,1000,123,-999};
        int[] chars={0,65535,32768,1000,123,65534};
        for(int y=0;y<2;y++)for(int x=0;x<3;x++){
            check(q3(x,y),ints[y*3+x]);check(m3(x,y),chars[y*3+x]);
        }
        j1=0;check(q3(2,Integer.MIN_VALUE),Integer.MIN_VALUE);check(m3(2,Integer.MIN_VALUE),32768);
        j1=2;check(q3(0,Integer.MIN_VALUE),-7);check(m3(0,Integer.MIN_VALUE),0);
        j1=-1;check(q3(1,1),-7);check(m3(1,1),0);
        j1=3;check(q3(-1,0),1000);check(m3(-1,0),1000);
        check(q3(6,0),1000);check(m3(6,0),1000);
        x3=null;u3=null;check(q3(0,0),1000);check(m3(0,0),1000);
        x3=new int[]{87654};u3=new char[]{65533};j1=1;
        check(q3(0,0),87654);check(m3(0,0),65533);
        System.out.println("LAB_MAP_ORACLE_PASS");
    }
}
