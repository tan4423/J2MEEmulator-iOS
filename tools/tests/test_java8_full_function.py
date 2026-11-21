"""Verify the complete Java 8 java.util.function API not present in CLDC.

Generated classes are compiled with Java 8 bytecode and compared to the JDK
reference API by public signatures, then behavior-tested under an isolated
non-java.* package so the host JVM cannot substitute its built-in classes.
"""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import generate_java8_function_boot

PATCHED = ROOT / 'J2MEEmulator' / 'RuntimePatches' / 'java' / 'util' / 'function'

JAVA_TEST = r'''
import jarbox.compat.function.*;
import java.util.Comparator;

public class Java8FunctionMatrix {
    static void eq(Object got, Object expected, String label) {
        if (!(got == expected || (got != null && got.equals(expected))))
            throw new AssertionError(label + ": " + got + " != " + expected);
    }
    static void require(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }
    public static void main(String[] args) {
        final StringBuilder events = new StringBuilder();
        BiConsumer<Integer,String> b1 = new BiConsumer<Integer,String>() {
            public void accept(Integer a, String b) { events.append('1'); }
        };
        BiConsumer<Integer,String> b2 = new BiConsumer<Integer,String>() {
            public void accept(Integer a, String b) { events.append('2'); }
        };
        b1.andThen(b2).accept(1,"x");
        eq(events.toString(), "12", "BiConsumer andThen");
        BiFunction<Integer,Integer,Integer> sum = new BiFunction<Integer,Integer,Integer>() {
            public Integer apply(Integer a,Integer b) { return a+b; }
        };
        Function<Integer,String> string = new Function<Integer,String>() {
            public String apply(Integer v) { return "v"+v; }
        };
        eq(sum.andThen(string).apply(2,3), "v5", "BiFunction andThen");
        final int[] count={0};
        BiPredicate<Integer,Integer> first = new BiPredicate<Integer,Integer>() {
            public boolean test(Integer a,Integer b) { count[0]++; return a>0; }
        };
        BiPredicate<Integer,Integer> second = new BiPredicate<Integer,Integer>() {
            public boolean test(Integer a,Integer b) { count[0]++; return b>0; }
        };
        require(!first.and(second).test(-1,1) && count[0]==1,"BiPredicate and short-circuit");
        count[0]=0;
        require(first.or(second).test(1,-1) && count[0]==1,"BiPredicate or short-circuit");
        require(first.negate().test(-1,3),"BiPredicate negate");
        eq(UnaryOperator.<Integer>identity().apply(12),12,"UnaryOperator identity");
        Comparator<Integer> cmp = new Comparator<Integer>() {
            public int compare(Integer a,Integer b) { return a.compareTo(b); }
        };
        eq(BinaryOperator.<Integer>minBy(cmp).apply(4,4),4,"minBy ties");
        eq(BinaryOperator.<Integer>maxBy(cmp).apply(4,9),9,"maxBy");
        require(new BooleanSupplier() { public boolean getAsBoolean() { return true; } }
                .getAsBoolean(),"BooleanSupplier");
        IntUnaryOperator inc = new IntUnaryOperator() {
            public int applyAsInt(int x) { return x + 1; }
        };
        IntUnaryOperator twice = new IntUnaryOperator() {
            public int applyAsInt(int x) { return x * 2; }
        };
        eq(inc.compose(twice).applyAsInt(7),15,"IntUnary.compose");
        eq(inc.andThen(twice).applyAsInt(7),16,"IntUnary.andThen");
        eq(IntUnaryOperator.identity().applyAsInt(9),9,"IntUnary.identity");
        LongUnaryOperator linc = new LongUnaryOperator() {
            public long applyAsLong(long x) { return x+1; }
        };
        eq(linc.compose(linc).applyAsLong(2),4L,"LongUnary.compose");
        eq(LongUnaryOperator.identity().applyAsLong(-9),-9L,"LongUnary.identity");
        DoubleUnaryOperator dinc = new DoubleUnaryOperator() {
            public double applyAsDouble(double v) { return v + 0.5; }
        };
        eq(dinc.andThen(dinc).applyAsDouble(2),3.0,"DoubleUnary.andThen");
        eq(DoubleUnaryOperator.identity().applyAsDouble(3.25),3.25,"DoubleUnary.identity");
        final int[] calls={0};
        IntPredicate p1 = new IntPredicate() {
            public boolean test(int value) { calls[0]++; return value > 0; }
        };
        IntPredicate p2 = new IntPredicate() {
            public boolean test(int value) { calls[0]++; return value%2==0; }
        };
        require(!p1.and(p2).test(-1) && calls[0]==1,"IntPredicate short circuit");
        calls[0]=0;
        require(p1.or(p2).test(1) && calls[0]==1,"IntPredicate or short circuit");
        require(p1.negate().test(-1),"IntPredicate negate");
        LongPredicate lp = new LongPredicate() {
            public boolean test(long v) {return v>0; }
        };
        require(lp.and(lp).test(1) && lp.negate().test(-1),"LongPredicate");
        DoublePredicate dp = new DoublePredicate() {
            public boolean test(double v) {return v>0; }
        };
        require(dp.or(dp).test(1.25) && dp.negate().test(-1),"DoublePredicate");
        eq(new IntBinaryOperator(){public int applyAsInt(int a,int b){return a+b;}}.applyAsInt(2,3),5,"IntBinary");
        eq(new LongBinaryOperator(){public long applyAsLong(long a,long b){return a+b;}}.applyAsLong(2,3),5L,"LongBinary");
        eq(new DoubleBinaryOperator(){public double applyAsDouble(double a,double b){return a+b;}}.applyAsDouble(2,3),5.0,"DoubleBinary");
        eq(new IntFunction<String>(){public String apply(int v){return "i"+v;}}.apply(3),"i3","IntFunction");
        eq(new LongFunction<String>(){public String apply(long v){return "l"+v;}}.apply(3),"l3","LongFunction");
        eq(new DoubleFunction<String>(){public String apply(double v){return "d"+v;}}.apply(2.5),"d2.5","DoubleFunction");
        eq(new IntToLongFunction(){public long applyAsLong(int v){return v;}}.applyAsLong(12),12L,"IntToLong");
        eq(new IntToDoubleFunction(){public double applyAsDouble(int v){return v;}}.applyAsDouble(12),12.0,"IntToDouble");
        eq(new LongToIntFunction(){public int applyAsInt(long v){return (int)v;}}.applyAsInt(12),12,"LongToInt");
        eq(new LongToDoubleFunction(){public double applyAsDouble(long v){return v;}}.applyAsDouble(12),12.0,"LongToDouble");
        eq(new DoubleToIntFunction(){public int applyAsInt(double v){return (int)v;}}.applyAsInt(12.5),12,"DoubleToInt");
        eq(new DoubleToLongFunction(){public long applyAsLong(double v){return (long)v;}}.applyAsLong(12.5),12L,"DoubleToLong");
        eq(new ToIntFunction<String>(){public int applyAsInt(String v){return v.length();}}.applyAsInt("abc"),3,"ToIntFunction");
        eq(new ToLongFunction<String>(){public long applyAsLong(String v){return v.length();}}.applyAsLong("abc"),3L,"ToLongFunction");
        eq(new ToDoubleFunction<String>(){public double applyAsDouble(String v){return v.length();}}.applyAsDouble("abc"),3.0,"ToDoubleFunction");
        eq(new ToIntBiFunction<String,String>(){public int applyAsInt(String a,String b){return a.length()+b.length();}}.applyAsInt("a","bb"),3,"ToIntBiFunction");
        eq(new ToLongBiFunction<String,String>(){public long applyAsLong(String a,String b){return a.length()+b.length();}}.applyAsLong("a","bb"),3L,"ToLongBiFunction");
        eq(new ToDoubleBiFunction<String,String>(){public double applyAsDouble(String a,String b){return a.length()+b.length();}}.applyAsDouble("a","bb"),3.0,"ToDoubleBiFunction");
        final long[] updates = {0};
        new ObjIntConsumer<String>(){ public void accept(String s,int n){updates[0]+=s.length()+n;} }.accept("aa",3);
        new ObjLongConsumer<String>(){ public void accept(String s,long n){updates[0]+=s.length()+n;} }.accept("aa",3L);
        new ObjDoubleConsumer<String>(){ public void accept(String s,double n){updates[0]+=s.length()+(long)n;} }.accept("aa",3.0);
        eq(updates[0],15L,"Obj primitive consumers");
        try { inc.compose(null); throw new AssertionError("compose null"); }
        catch (NullPointerException expected) { }
        try { b1.andThen(null); throw new AssertionError("BiConsumer null"); }
        catch (NullPointerException expected) { }
        try { BinaryOperator.minBy(null); throw new AssertionError("comparator null"); }
        catch (NullPointerException expected) { }
    }
}
'''


class Java8FullFunctionTest(unittest.TestCase):
    def test_full_java8_function_api(self):
        if not all(shutil.which(x) for x in ("javac", "java", "javap")):
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory(prefix='jarbox-full-functions-') as temp:
            base = pathlib.Path(temp)
            files = generate_java8_function_boot.write_generated(base / 'generated/java/util/function')
            self.assertEqual(33, len(files))
            compiled = base / 'boot_classes'
            sources = list((base / 'generated/java/util/function').glob('*.java'))
            subprocess.run(['javac', '--release', '8', '-d', str(compiled)] + list(map(str, sources)),
                           check=True, capture_output=True, text=True)
            for name in files:
                actual = subprocess.run(['javap', '-public', str(compiled / 'java/util/function' / (name+'.class'))],
                                        check=True, capture_output=True, text=True).stdout
                expected = subprocess.run(['javap', '-public', 'java.util.function.'+name],
                                          check=True, capture_output=True, text=True).stdout
                def signatures(value):
                    return set(x.strip() for x in value.splitlines()
                               if x.strip().startswith('public abstract ') or
                               x.strip().startswith('public default ') or
                               x.strip().startswith('public static '))
                self.assertEqual(signatures(expected), signatures(actual), name)
            # Rename only generated source packages; runtime Java 8 methods
            # now run from our own classfiles, not from the host java.base.
            renamed = base / 'renamed'
            renamed.mkdir()
            test_sources=[]
            for name in files:
                src = (base/'generated/java/util/function'/(name+'.java')).read_text()
                src = src.replace('package java.util.function;', 'package jarbox.compat.function;', 1)
                (renamed / (name+'.java')).write_text(src)
                test_sources.append(str(renamed/(name+'.java')))
            # Existing Function / Predicate are dependencies of BinaryOperator.
            # Their original sources are package-renamed for host isolation too.
            for name in ('Function', 'Predicate'):
                src=(PATCHED/(name+'.java')).read_text()
                src=src.replace('package java.util.function;', 'package jarbox.compat.function;',1)
                (renamed/(name+'.java')).write_text(src)
                test_sources.append(str(renamed/(name+'.java')))
            fixture=base/'Java8FunctionMatrix.java'
            fixture.write_text(JAVA_TEST)
            output=base/'isolated'
            subprocess.run(['javac','--release','8','-d',str(output)] + test_sources + [str(fixture)],
                           check=True,capture_output=True,text=True)
            subprocess.run(['java','-cp',str(output),'Java8FunctionMatrix'],
                           check=True,capture_output=True,text=True)
            # Generated default helpers are Java 8 classfiles and do not
            # themselves require invokedynamic / LambdaMetafactory.
            helper_files = list((output/'jarbox/compat/function').glob('*.class'))
            self.assertGreater(len(helper_files), 40)
            for helper in helper_files:
                bytecode = subprocess.run(['javap','-c',str(helper)],check=True,
                                         capture_output=True,text=True).stdout
                self.assertNotIn('invokedynamic', bytecode, helper.name)


if __name__ == '__main__':
    unittest.main()
