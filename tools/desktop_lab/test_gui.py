"""Test JarBox settings persistence, validation, GUI and private export allowlist."""
import pathlib
import tempfile
import tkinter as tk
import sys
import zipfile

root=pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0,str(root))
import gui

with tempfile.TemporaryDirectory() as tmp:
    tmp=pathlib.Path(tmp)
    gui.CONFIG_DIR=tmp/"config"
    gui.CONFIG_PATH=gui.CONFIG_DIR/"settings.json"
    gui.BASE=tmp/"data"
    # Boundary, persistence and independent save identities without sleeping.
    p=tmp/"cooldown.lock"
    with p.open("a+") as lock:
        assert gui.relaunch_remaining(lock,now=100)==0
        gui.mark_retired(lock,now=100)
        assert gui.relaunch_remaining(lock,now=130)>0
        assert gui.relaunch_remaining(lock,now=131)==0
        assert gui.relaunch_remaining(lock,now=90)==31
    with p.open("a+") as lock:
        assert gui.relaunch_remaining(lock,now=120)==11
    with (tmp/"other.lock").open("a+") as lock:
        assert gui.relaunch_remaining(lock,now=120)==0
    window=tk.Tk()
    window.withdraw()
    app=gui.Lab(window)
    assert app.w.get()=="240" and app.h.get()=="320"
    assert app.mode.get()=="graph"
    assert app.settings_btn is not None
    target=tmp/"custom-data"
    values={"default_jar":"/mnt/e/Games/NSO/Nick.jar","width":176,"height":220,
            "mode":"plain","data_dir":str(target),"refresh_ms":2000}
    app._apply_settings(values)
    assert app.w.get()=="176" and app.h.get()=="220"
    assert app.mode.get()=="plain" and app.refresh_ms==2000
    assert gui.BASE==target and target.is_dir()
    assert gui.load_settings()==gui.validate_settings(values)
    try:
        gui.validate_settings({**values,"width":20})
        raise AssertionError("invalid width accepted")
    except ValueError:
        pass
    try:
        gui.validate_settings({**values,"mode":"unsafe"})
        raise AssertionError("invalid mode accepted")
    except ValueError:
        pass
    app.open_settings()
    dialogs=[w for w in window.winfo_children() if isinstance(w,tk.Toplevel)]
    assert dialogs,"Settings dialog was not opened"
    dialogs[-1].destroy()
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
print("LAB_GUI_SETTINGS_PASS")
print("LAB_GUI_EXPORT_PASS")
