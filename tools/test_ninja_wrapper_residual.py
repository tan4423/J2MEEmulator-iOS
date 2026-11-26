import unittest
from ninja_wrapper_residual import plan, G

KEY=('t','a','(IIII)V')
FIELD='#6 // Field b:I'
DRAW='#9 // Method '+G+'.drawLine:(IIII)V'


def fixture():
    ops=[('iload_1',''),('getstatic',FIELD),('imul',''),('istore_1',''),
         ('aload_0',''),('getfield','#5 // Field a:L'+G+';'),
         ('iload_1',''),('iload_2',''),('iload_3',''),('iload','4'),
         ('invokevirtual',DRAW),('return','')]
    return {'decl':'public final void a(int,int,int,int);','handlers':False,'switch_targets':set(),
            'ins':[(i,op,arg) for i,(op,arg) in enumerate(ops)]}


class ResidualTests(unittest.TestCase):
    def test_preserve_reads_receiver_and_fallback_roots(self):
        p=plan(KEY,fixture())
        self.assertEqual(p['retain_pcs'],[1,4,5,10,11])
        self.assertEqual(p['conditional_dead_pcs'],[0,2,3,6,7,8,9])
        self.assertEqual([x['pc'] for x in p['ordered_reads']],[1,5])
        self.assertEqual(p['guarded_call']['argument_roots'],[6,7,8,9])
        self.assertEqual(p['dependencies']['6'],[3])
        self.assertEqual(p['dependencies']['3'],[2])
        self.assertEqual(p['dependencies']['2'],[0,1])
        self.assertFalse(p['runtime_authorized'])
    def test_reject_effects_and_throwing_ops(self):
        for op,arg in [('idiv',''),('putstatic',FIELD),('iastore',''),('monitorenter',''),('new','#2'),('goto','10'),('invokestatic','#3 // Method clock:()I')]:
            m=fixture();m['ins'][2]=(2,op,arg)
            self.assertIsNone(plan(KEY,m),op)
    def test_reject_handler_sync_and_unknown_sink(self):
        for k,v in [('handlers',True),('switch_targets',{10}),('decl','public synchronized void a();')]:
            m=fixture();m[k]=v;self.assertIsNone(plan(KEY,m))
        m=fixture();m['ins'][10]=(10,'invokevirtual',DRAW.replace('drawLine','copyArea'))
        self.assertIsNone(plan(KEY,m))
    def test_reject_extra_stack_and_wide_field(self):
        m=fixture();m['ins'].insert(0,(-1,'iconst_0',''));self.assertIsNone(plan(KEY,m))
        m=fixture();m['ins'][1]=(1,'getstatic',FIELD.replace(':I',':J'));self.assertIsNone(plan(KEY,m))

if __name__=='__main__':unittest.main()
