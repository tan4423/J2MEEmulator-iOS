import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;

public final class LabFixture extends MIDlet {
    protected void startApp() {
        Display.getDisplay(this).setCurrent(new Probe());
    }
    protected void pauseApp() {}
    protected void destroyApp(boolean unconditional) {}
    final class Probe extends Canvas {
        protected void paint(Graphics g) {
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
            System.out.println("LAB_FIXTURE_PIXEL_PASS");
            notifyDestroyed();
        }
    }
}
