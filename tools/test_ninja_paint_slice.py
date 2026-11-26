import unittest
from ninja_paint_slice import parse, member, suffix, kind, G

class SliceTests(unittest.TestCase):
    def test_constructor_vs_same_name_method(self):
        cls, meth = parse('''public final class b {
  public b();
    descriptor: ()V
    Code:
       0: return
  public void b();
    descriptor: ()V
    Code:
       0: return
}
''')
        self.assertEqual(set(meth),{('b','<init>','()V'),('b','b','()V')})
    def test_field_resolution(self):
        self.assertEqual(member('t','#5 // Field a:Ljavax/microedition/lcdui/Graphics;'),('t','a','Ljavax/microedition/lcdui/Graphics;'))
        self.assertEqual(member('main/a','#271 // Field t.a:Ljavax/microedition/lcdui/Graphics;'),('t','a','Ljavax/microedition/lcdui/Graphics;'))
    def test_pure_suffix(self):
        ref=(G,'fillRect','(IIII)V')
        m={'handlers':False,'switch_targets':set(),'ins':[(0,'aload_0',''),(1,'iload_1',''),(2,'iconst_2',''),(3,'imul',''),(4,'iconst_0',''),(5,'iconst_1',''),(6,'iconst_1',''),(7,'invokevirtual','')]}
        self.assertEqual(suffix(m,7,ref),[6,5,4,3,2,1])
        m['handlers']=True
        self.assertEqual(suffix(m,7,ref),[])
        m['handlers']=False;m['switch_targets']={4}
        self.assertEqual(suffix(m,7,ref),[])
        m['switch_targets']=set();m['ins'][3]=(3,'idiv','')
        self.assertEqual(suffix(m,7,ref),[])
    def test_categories(self):
        self.assertEqual(kind((G,'drawImage','(Ljavax/microedition/lcdui/Image;III)V')),'possible_screen_sink')
        self.assertEqual(kind((G,'getClipWidth','()I')),'query_keep')
        for ref in [(G,'setClip','(IIII)V'),(G,'getPixels','([IIIIIII)V'),('javax/microedition/lcdui/Image','createImage','(II)Ljavax/microedition/lcdui/Image;'),('java/lang/System','currentTimeMillis','()J')]:
            self.assertEqual(kind(ref),'external_effect_or_unknown_keep')
if __name__=='__main__':unittest.main()
