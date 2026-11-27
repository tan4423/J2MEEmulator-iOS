"""Test GUI construction and the private export allowlist in the built bundle."""
import importlib.util
import pathlib
import tempfile
import tkinter as tk
import sys
import zipfile

root=pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0,str(root))
import gui
with tempfile.TemporaryDirectory() as tmp:
    gui.BASE=pathlib.Path(tmp)
    window=tk.Tk()
    window.withdraw()
    app=gui.Lab(window)
    app.session=gui.BASE/"session"
    app.session.mkdir()
    allowed=("session.json","trace.csv","trace.csv.edges.tsv","trace.csv.effects.csv","trace.csv.network.csv")
    for name in allowed+("private-runtime.log","game.jar","rms.dat"):
        (app.session/name).write_text("fixture")
    path=gui.BASE/"export.zip"
    gui.filedialog.asksaveasfilename=lambda **kw:str(path)
    gui.messagebox.showinfo=lambda *a,**kw:None
    app.export()
    with zipfile.ZipFile(path) as z:
        assert set(z.namelist())==set(allowed),z.namelist()
    window.update_idletasks()
    window.destroy()
print("LAB_GUI_EXPORT_PASS")
