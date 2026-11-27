"""Corpus tool safety tests, without distributing any game JAR."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import ninja_headless_corpus as corpus

class HeadlessCorpusTest(unittest.TestCase):
    def test_exact_identity_only(self):
        seen=set()
        for family,p in corpus.PROFILES.items():
            for sha in p['hashes']:
                self.assertEqual(len(sha),64)
                self.assertNotIn(sha,seen)
                seen.add(sha)
                self.assertEqual(corpus.identify(sha)[0],family)
        self.assertEqual(len(seen),5)
        with self.assertRaises(ValueError):
            corpus.identify('0'*64)

    def test_constructor_not_method_same_name(self):
        text="""public class b {
  public b();
    descriptor: ()V
    Code:
       0: return
  public void b();
    descriptor: ()V
    Code:
       0: return
}
"""
        self.assertEqual(set(corpus.parse(text)),{('b','<init>','()V'),('b','b','()V')})

    def test_witness_exact_pc_and_symbol(self):
        key=('C','a','()V')
        m={key:[(10,'putfield','#1 // Field f:I')]}
        self.assertEqual(corpus.require(m,key,10,'putfield','C.f:I')['pc'],10)
        for pc,op,symbol in [(11,'putfield','C.f:I'),(10,'getfield','C.f:I'),(10,'putfield','D.f:I')]:
            with self.assertRaises(ValueError):
                corpus.require(m,key,pc,op,symbol)

    def test_direct_effects_not_purity(self):
        result=corpus.effects([(0,'getfield',''),(3,'putfield',''),(6,'aastore',''),
            (7,'new',''),(10,'invokevirtual',''),(13,'arraylength',''),
            (14,'monitorenter',''),(15,'goto','0')])
        self.assertEqual(result,dict(instructions=8,field_reads=1,writes=2,allocations=1,
            calls=1,explicit_fault_sites=3,monitor_ops=1,backedges=1))
        self.assertEqual(corpus.symbol('main.b','#1 // Method main/c.a:()V'),'main.c.a:()V')

if __name__=='__main__':
    unittest.main()
